defmodule Parlora.AudioPipeline do
  @moduledoc false
  use GenServer
  alias Parlora.{Adapter, CommandLog, Error, Event, Pacer}
  alias Parlora.Session.Health

  # Channel clocks consume audio independently. Admit a bounded burst per turn
  # instead of adding a timer between each fragment of an already received packet.
  @transfer_burst_frames 20

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def control(pid, id, control), do: Adapter.call(pid, {:control, id, control})

  @impl true
  def init(options) do
    state =
      Map.new(options)
      |> Map.merge(%{
        output_pacing: Keyword.get(options, :output_pacing, :pipeline),
        health_counters: Keyword.get(options, :health_counters),
        pending: [],
        ready_ref: nil,
        space_ref: nil,
        tick_timer: nil,
        tick_token: nil,
        blocked_since_us: nil,
        epoch: 0,
        suppressed: false,
        commands: %CommandLog{limit: Keyword.fetch!(options, :init).limits.max_records},
        deadline: System.monotonic_time(:microsecond)
      })

    if Keyword.has_key?(options, :startup_owner) do
      {:ok, state, {:continue, :initialize}}
    else
      discard_preready_input(state)
      send(self(), :tick)
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    discard_preready_input(state)
    send(state.startup_owner, {:parlora_pipeline_ready, self(), state.startup_token})
    {:noreply, state}
  end

  defp discard_preready_input(%{direction: :input} = state) do
    case discard_source(state) do
      {:ok, [_frame | _rest] = frames} ->
        Event.emit(state.init, :session, :audio_discontinuity, %{
          direction: :input,
          cause: :startup_buffer_discard,
          frames: length(frames),
          duration_us: Enum.reduce(frames, 0, &(&1.duration_us + &2))
        })

      _empty_or_unavailable ->
        :ok
    end
  end

  defp discard_preready_input(_state), do: :ok

  @impl true
  def handle_call({:control, id, control}, _from, state) do
    case CommandLog.admit(state.commands, id, control) do
      {:duplicate, log} -> {:reply, CommandLog.reply(log, id), state}
      {:new, log} -> CommandLog.complete(apply_control(state, id, control), log, id)
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:activate_pipeline, token}, %{startup_token: token} = state) do
    send(self(), :tick)

    {:noreply,
     state
     |> Map.delete(:startup_token)
     |> Map.put(:deadline, System.monotonic_time(:microsecond))}
  end

  def handle_info({:activate_pipeline, _old_token}, state), do: {:noreply, state}

  def handle_info({:tick, token}, %{tick_token: token} = state),
    do: handle_info(:tick, state)

  def handle_info({:tick, _old_token}, state), do: {:noreply, state}

  def handle_info(
        {:parlora_audio_ready, source, reference},
        %{source: {_module, source}, ready_ref: reference, pending: [], suppressed: false} = state
      )
      when is_reference(reference) do
    handle_info(:tick, %{state | ready_ref: nil, deadline: System.monotonic_time(:microsecond)})
  end

  def handle_info({:parlora_audio_ready, _source, _reference}, state), do: {:noreply, state}

  def handle_info(
        {:parlora_output_space, destination, reference},
        %{destination: {_module, destination}, space_ref: reference, suppressed: false} = state
      )
      when is_reference(reference) do
    handle_info(:tick, %{state | space_ref: nil, deadline: System.monotonic_time(:microsecond)})
  end

  def handle_info({:parlora_output_space, _destination, _reference}, state),
    do: {:noreply, state}

  def handle_info(:tick, state) do
    if state.tick_timer, do: Process.cancel_timer(state.tick_timer)
    started = System.monotonic_time(:microsecond)
    {next, duration_us} = transfer(state)
    finished = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:parlora, :audio, :tick],
      %{
        at_us: started,
        work_us: finished - started,
        late_us: max(0, started - state.deadline),
        pending_frames: length(next.pending),
        blocked: if(next.blocked_since_us == nil, do: 0, else: 1),
        delay_ms: max(1, div(duration_us + 999, 1_000))
      },
      %{direction: state.direction, session_id: state.init.session_id}
    )

    {deadline, wait_ms} = Pacer.next(state.deadline, duration_us)
    token = make_ref()
    timer = Process.send_after(self(), {:tick, token}, wait_ms)
    {:noreply, %{next | deadline: deadline, tick_timer: timer, tick_token: token}}
  end

  def handle_info(
        {:backpressure_timeout, epoch, since},
        %{epoch: epoch, blocked_since_us: since} = state
      ),
      do: {:stop, :normal, state}

  def handle_info({:backpressure_timeout, _old_epoch, _old_since}, state),
    do: {:noreply, state}

  defp apply_control(state, id, {:provider_interrupted, _token}) do
    next = state.epoch + 1
    {module, pid} = state.destination

    case module.control(pid, id, {:clear_output, next}) do
      :ok ->
        # The provider already dropped old audio and holds new output until this
        # barrier completes. Reading/discarding its source here loses new speech.
        {:reply, :ok,
         %{
           state
           | epoch: next,
             pending: [],
             blocked_since_us: nil,
             ready_ref: nil,
             space_ref: nil
         }}

      error ->
        {:reply, error, state}
    end
  end

  defp apply_control(state, id, {:clear_output, _epoch}) do
    next = state.epoch + 1
    {module, pid} = state.destination
    reply = module.control(pid, id, {:clear_output, next})

    if reply == :ok do
      discard_reply(%{state | epoch: next})
    else
      {:reply, reply, state}
    end
  end

  defp apply_control(state, id, {:suppress_output, flag} = control) when is_boolean(flag) do
    {module, pid} = state.destination

    case module.control(pid, id, control) do
      :ok ->
        next = %{state | suppressed: flag}
        if flag or state.suppressed, do: discard_reply(next), else: {:reply, :ok, next}

      error ->
        {:reply, error, state}
    end
  end

  defp apply_control(state, id, control) do
    {module, pid} = state.destination
    {:reply, module.control(pid, id, control), state}
  end

  defp discard_reply(state) do
    next = %{state | pending: [], blocked_since_us: nil, ready_ref: nil, space_ref: nil}

    case discard_source(state) do
      {:ok, _frames} -> {:reply, :ok, next}
      error -> {:reply, error, next}
    end
  end

  defp refill(%{suppressed: true} = state) do
    case discard_source(state) do
      {:ok, _frames} ->
        state

      {:error, error} ->
        report(state, error)
        state
    end
  end

  defp refill(%{pending: []} = state) do
    {module, pid} = state.source

    case module.read_audio(pid, state.init.limits.max_frame_bytes) do
      {:ok, []} ->
        arm_source(state)

      {:ok, frames} ->
        %{state | pending: frames, ready_ref: nil}

      {:error, error} ->
        report(state, error)
        state
    end
  end

  defp refill(state), do: state

  defp transfer(%{direction: :output, output_pacing: :channel, suppressed: false} = state),
    do: transfer_burst(state, @transfer_burst_frames)

  defp transfer(state) do
    {next, delay, _accepted} = state |> refill() |> forward()
    {next, delay}
  end

  defp transfer_burst(state, remaining) do
    ready = refill(state)
    {next, delay, accepted} = forward(ready)

    if remaining > 1 and accepted do
      {next, burst_delay} = transfer_burst(next, remaining - 1)
      # Preserve the short follow-up poll after draining a received burst for
      # adapters without readiness hints. Backpressure keeps its normal wait.
      {next, if(next.pending == [] and next.ready_ref == nil, do: delay, else: burst_delay)}
    else
      {next, delay}
    end
  end

  defp arm_source(%{ready_ref: nil, direction: :output, output_pacing: :channel} = state) do
    {module, pid} = state.source
    reference = make_ref()

    if function_exported?(module, :arm_output_ready, 3) and
         module.arm_output_ready(pid, self(), reference) == :ok,
       do: %{state | ready_ref: reference},
       else: state
  end

  defp arm_source(state), do: state

  defp forward(%{pending: []} = state), do: {state, state.init.limits.tick_ms * 1_000, false}

  defp forward(%{pending: [frame | rest]} = state) do
    {module, pid} = state.destination
    frame = if state.direction == :output, do: %{frame | playback_epoch: state.epoch}, else: frame

    case module.write_audio(pid, frame) do
      :ok ->
        Health.transferred(state.health_counters, state.direction, frame)

        :telemetry.execute(
          [:parlora, :audio, :frame],
          %{
            at_us: System.monotonic_time(:microsecond),
            bytes: byte_size(frame.data),
            duration_us: frame.duration_us
          },
          %{direction: state.direction, session_id: state.init.session_id}
        )

        {%{state | pending: rest, blocked_since_us: nil, space_ref: nil},
         transfer_delay(state, frame), true}

      {:error, %Error{code: :backpressure}} ->
        relieve_pressure(state)
        now = System.monotonic_time(:microsecond)
        since = state.blocked_since_us || now

        if now - since >= state.init.limits.audio_backpressure_timeout_ms * 1_000 do
          report(state, Error.new(:timeout, "Audio consumer remained blocked"))
          send(self(), {:backpressure_timeout, state.epoch, since})
        end

        {arm_destination(%{state | blocked_since_us: since}, byte_size(frame.data)),
         state.init.limits.tick_ms * 1_000, false}

      {:error, error} ->
        report(state, error)
        {%{state | pending: rest, space_ref: nil}, state.init.limits.tick_ms * 1_000, false}
    end
  end

  # Hardware/RTP owns playout timing for these channels. Refill their bounded
  # queues promptly instead of imposing a second real-time clock after jitter.
  defp transfer_delay(%{direction: :output, output_pacing: :channel}, _frame), do: 1_000
  defp transfer_delay(_state, frame), do: frame.duration_us

  defp arm_destination(
         %{direction: :output, output_pacing: :channel, space_ref: nil} = state,
         bytes
       ) do
    {module, pid} = state.destination
    reference = make_ref()

    if function_exported?(module, :arm_output_space, 5) and
         module.arm_output_space(pid, self(), reference, bytes, state.epoch) == :ok,
       do: %{state | space_ref: reference},
       else: state
  end

  defp arm_destination(state, _bytes), do: state

  defp relieve_pressure(%{direction: :output, output_pacing: :channel} = state) do
    {source, source_pid} = state.source
    {destination, destination_pid} = state.destination

    with true <- function_exported?(source, :output_buffer_status, 1),
         true <- function_exported?(destination, :release_output_recovery, 2),
         {:ok, %{queued_bytes: bytes, capacity_bytes: capacity}} <-
           source.output_buffer_status(source_pid),
         true <- is_integer(bytes) and bytes >= 0 and is_integer(capacity) and capacity > 0,
         threshold <- min(div(capacity, 2), state.init.limits.audio_queue_bytes),
         true <- bytes + pending_bytes(state) >= threshold do
      reply = destination.release_output_recovery(destination_pid, state.epoch)

      :telemetry.execute(
        [:parlora, :audio, :recovery_pressure],
        %{
          at_us: System.monotonic_time(:microsecond),
          queued_bytes: bytes,
          capacity_bytes: capacity,
          pending_bytes: pending_bytes(state),
          threshold_bytes: threshold
        },
        %{session_id: state.init.session_id, epoch: state.epoch, accepted: reply == :ok}
      )
    end

    :ok
  end

  defp relieve_pressure(_state), do: :ok

  defp pending_bytes(state), do: Enum.reduce(state.pending, 0, &(byte_size(&1.data) + &2))

  defp discard_source(state) do
    {module, pid} = state.source
    limits = state.init.limits

    budget =
      if state.direction == :output,
        do: max(limits.audio_queue_bytes, limits.provider_audio_queue_bytes),
        else: limits.audio_queue_bytes

    module.read_audio(pid, budget)
  end

  defp report(state, error) do
    Event.emit(state.init, :session, :audio_discontinuity, %{
      direction: state.direction,
      cause: error.code
    })
  end
end
