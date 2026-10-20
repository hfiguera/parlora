defmodule Parlora.TestSupport.MemoryAudio do
  @moduledoc false
  use GenServer

  alias Parlora.{
    Adapter,
    AudioFormat,
    AudioFrame,
    AudioQueue,
    CommandLog,
    Error,
    Event,
    OutputSpace
  }

  defmacro __using__(options) do
    role = Keyword.fetch!(options, :role)
    behaviour = if role == :channel, do: Parlora.Channel, else: Parlora.Provider

    quote do
      @behaviour unquote(behaviour)
      alias Parlora.TestSupport.MemoryAudio
      @impl true
      def start_link(init, options), do: MemoryAudio.start_link(init, unquote(role), options)
      @impl true
      defdelegate capabilities(pid), to: MemoryAudio
      @impl true
      defdelegate close(pid, id, reason), to: MemoryAudio
      @impl true
      defdelegate read_audio(pid, budget), to: MemoryAudio
      @impl true
      defdelegate write_audio(pid, frame), to: MemoryAudio
      @impl true
      defdelegate control(pid, id, control), to: MemoryAudio

      if unquote(role) == :provider do
        @impl true
        defdelegate append_context(pid, update), to: MemoryAudio
      end
    end
  end

  def start_link(init, role, options), do: GenServer.start_link(__MODULE__, {init, role, options})
  def capabilities(pid), do: Adapter.call(pid, :capabilities)
  def close(pid, id, reason), do: Adapter.call(pid, {:close, id, reason})
  def read_audio(pid, budget), do: Adapter.call(pid, {:read, budget})
  def write_audio(pid, frame), do: Adapter.call(pid, {:write, frame})
  def control(pid, id, control), do: Adapter.call(pid, {:command, id, control})

  def append_context(pid, update),
    do: Adapter.call(pid, {:command, update.id, {:context, update}})

  def inject(pid, type, payload, fields \\ []),
    do: Adapter.call(pid, {:inject, type, payload, fields})

  def audio(pid, frame), do: Adapter.call(pid, {:audio, frame})
  def drain(pid), do: Adapter.call(pid, :drain)

  def arm_output_ready(pid, reader, reference),
    do: Adapter.call(pid, {:arm_output_ready, reader, reference})

  def output_buffer_status(pid), do: Adapter.call(pid, :output_buffer_status)

  def release_output_recovery(pid, epoch),
    do: Adapter.call(pid, {:release_output_recovery, epoch})

  def arm_output_space(pid, writer, reference, bytes, epoch),
    do: Adapter.call(pid, {:arm_output_space, writer, reference, bytes, epoch})

  @impl true
  def init({init, role, options}) do
    observer = Keyword.get(options, :observer)
    if observer, do: send(observer, {:adapter, role, self()})
    capabilities = Keyword.get(options, :capabilities, default_capabilities(role))
    unless Keyword.get(options, :delay_ready, false), do: send(self(), :ready)

    {:ok,
     %{
       init: init,
       role: role,
       ready: false,
       capabilities: capabilities,
       options: options,
       inbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       commands: %CommandLog{limit: init.limits.max_records},
       closed: false,
       epoch: 0,
       suppressed: false,
       audio_waiter: nil,
       output_waiter: nil,
       recovery_release_epoch: nil
     }}
  end

  @impl true
  def handle_info(:ready, state) do
    Event.emit(state.init, state.role, :ready, %{
      capabilities: state.capabilities,
      format: state.init.audio_format
    })

    {:noreply, %{state | ready: true}}
  end

  @impl true
  def handle_call({:recover_output, token, snapshot}, _from, state) do
    if observer = Keyword.get(state.options, :observer),
      do: send(observer, {:output_recovery, token, snapshot})

    {:reply, :ok, state}
  end

  def handle_call({:inject, type, payload, fields}, _from, state) do
    Event.emit(state.init, state.role, type, payload, fields)
    {:reply, :ok, state}
  end

  def handle_call({:close, id, _reason}, _from, state) do
    unless state.closed or Keyword.get(state.options, :no_close_event, false) do
      Event.emit(state.init, state.role, :closed, %{finalized?: true}, command_id: id)
    end

    {:reply, :ok, %{state | closed: true}}
  end

  def handle_call(_call, _from, %{closed: true} = state),
    do: {:reply, Error.tuple(:closed, "Closed"), state}

  def handle_call(_call, _from, %{ready: false} = state),
    do: {:reply, Error.tuple(:not_ready, "Not ready"), state}

  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, state.capabilities}, state}

  def handle_call(:output_buffer_status, _from, state) do
    reply =
      if Keyword.get(state.options, :pressure_status, true),
        do: {:ok, %{queued_bytes: state.inbound.bytes, capacity_bytes: state.inbound.capacity}},
        else: Error.tuple(:unsupported, "No buffer status")

    {:reply, reply, state}
  end

  def handle_call({:release_output_recovery, epoch}, _from, %{epoch: epoch} = state),
    do: {:reply, :ok, %{state | recovery_release_epoch: epoch}}

  def handle_call({:release_output_recovery, _epoch}, _from, state), do: {:reply, :ok, state}

  def handle_call({:arm_output_space, writer, reference, bytes, epoch}, _from, state) do
    if Keyword.get(state.options, :output_space, false),
      do: {:reply, :ok, OutputSpace.arm(state, writer, reference, bytes, epoch)},
      else: {:reply, Error.tuple(:unsupported, "No space hints"), state}
  end

  def handle_call({:arm_output_ready, reader, reference}, _from, state) do
    if Keyword.get(state.options, :audio_ready, false) do
      {:reply, :ok, ready_audio(%{state | audio_waiter: {reader, reference}})}
    else
      {:reply, Error.tuple(:unsupported, "No readiness hints"), state}
    end
  end

  def handle_call({:read, budget}, _from, state)
      when is_integer(budget) and budget >= state.init.limits.max_frame_bytes do
    {frames, queue} = AudioQueue.pop(state.inbound, budget)

    {:reply, {:ok, frames},
     %{state | inbound: queue, audio_waiter: if(frames == [], do: state.audio_waiter, else: nil)}}
  end

  def handle_call({:audio, frame}, _from, state) do
    case AudioQueue.push(state.inbound, frame) do
      {:ok, queue} -> {:reply, :ok, ready_audio(%{state | inbound: queue})}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _from, state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         :ok <- epoch_valid(state, frame),
         {:ok, queue} <- AudioQueue.push(state.outbound, frame) do
      queue = if state.suppressed, do: state.outbound, else: queue

      if state.options[:observe_writes] == true and is_pid(state.options[:observer]) do
        send(state.options[:observer], {:audio_written, self(), frame})
      end

      {:reply, :ok, %{state | outbound: queue}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:drain, _from, state) do
    {frames, queue} = AudioQueue.pop(state.outbound, state.init.limits.audio_queue_bytes)
    {:reply, frames, OutputSpace.notify(%{state | outbound: queue})}
  end

  def handle_call({:command, id, command}, _from, state) do
    case CommandLog.admit(state.commands, id, command) do
      {:duplicate, log} -> {:reply, CommandLog.reply(log, id), state}
      {:new, log} -> CommandLog.complete(execute(state, id, command), log, id)
      error -> {:reply, error, state}
    end
  end

  def handle_call(_call, _from, state),
    do: {:reply, Error.tuple(:invalid_argument, "Invalid call"), state}

  defp execute(state, id, {:context, update}) do
    if observer = Keyword.get(state.options, :observer), do: send(observer, {:context, update})

    type =
      if Keyword.get(state.options, :reject_context, false),
        do: :context_rejected,
        else: :context_acknowledged

    unless Keyword.get(state.options, :delay_context_ack, false),
      do: Event.emit(state.init, state.role, type, %{}, command_id: id)

    {:reply, :ok, state}
  end

  defp execute(state, id, {:clear_output, epoch}) when epoch > state.epoch do
    Event.emit(
      state.init,
      state.role,
      :control_completed,
      %{epoch: epoch, scope: :parlora_buffers},
      command_id: id
    )

    {:reply, :ok,
     %{state | outbound: AudioQueue.clear(state.outbound), epoch: epoch, output_waiter: nil}}
  end

  defp execute(state, id, {:suppress_output, flag}) when is_boolean(flag) do
    Event.emit(state.init, state.role, :control_completed, %{}, command_id: id)
    {:reply, :ok, %{state | suppressed: flag, output_waiter: nil}}
  end

  defp execute(state, id, {:input_muted, flag}) when is_boolean(flag) do
    Event.emit(state.init, state.role, :control_completed, %{muted: flag}, command_id: id)
    {:reply, :ok, state}
  end

  defp execute(state, _id, _command),
    do: {:reply, Error.tuple(:unsupported, "Unsupported control"), state}

  defp epoch_valid(%{role: :channel, epoch: epoch}, %{playback_epoch: epoch}), do: :ok
  defp epoch_valid(%{role: :provider}, _frame), do: :ok
  defp epoch_valid(_state, _frame), do: Error.tuple(:invalid_argument, "Stale playback epoch")

  defp default_capabilities(:channel) do
    %Parlora.Channel.Capabilities{
      input_formats: [%AudioFormat{}],
      output_formats: [%AudioFormat{}],
      full_duplex?: true,
      output_suppression?: true,
      clear_scope: :parlora_buffers,
      playback_evidence: [:queue]
    }
  end

  defp default_capabilities(:provider) do
    %Parlora.Provider.Capabilities{
      audio_formats: [%AudioFormat{}],
      full_duplex?: true,
      transcripts: [:user, :assistant],
      delegation_modes: [:client],
      context_update_kinds: [:quiet, :speakable, :instruction],
      input_mute?: true,
      usage?: true
    }
  end

  defp ready_audio(%{audio_waiter: {pid, ref}, inbound: %{bytes: bytes}} = state)
       when bytes > 0 do
    send(pid, {:parlora_audio_ready, self(), ref})
    %{state | audio_waiter: nil}
  end

  defp ready_audio(state), do: state
end
