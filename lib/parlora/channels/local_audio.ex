defmodule Parlora.Channels.LocalAudio do
  @moduledoc """
  CPAL microphone and speaker audio, converted through Rubato to mono PCM16/24 kHz.

  Options: `:host` (CoreAudio or PulseAudio), `:input_device` and `:output_device`
  (device IDs), `:native_capacity_frames` (default 4,800), and `:target_buffer_ms`
  (default 30). `:playback_buffer_ms` (default 120, range 0–200) cushions delivery
  jitter before starting playback. `:playback_buffering` defaults to `:adaptive`
  (or use `:fixed`): the target learns between that cushion and 200 ms, capped
  by queue duration. `:playback_recovery_ms` independently caps recovery waiting
  (default 120, range 0–200), with early release under upstream pressure.
  Zero initial cushion disables buffering.
  Queue and callback handoff are observable; neither proves human hearing.
  """
  use GenServer
  use Parlora.AdapterClient, output_space: true
  @behaviour Parlora.Channel
  alias Parlora.{
    Adapter,
    AudioClock,
    AudioConverter,
    AudioFormat,
    AudioFrame,
    AudioQueue,
    CommandLog,
    Error,
    Event,
    Native,
    OutputSpace,
    Playout
  }

  alias Parlora.Channel.Capabilities
  alias Parlora.Native.Device
  alias Parlora.Native.Resampler

  @impl true
  def start_link(init, options) do
    capacity = Keyword.get(options, :native_capacity_frames, 4_800)
    target = Keyword.get(options, :target_buffer_ms, 30)
    playback = Keyword.get(options, :playback_buffer_ms, 120)

    if is_integer(capacity) and capacity in 16..48_000 and is_integer(target) and
         target in 1..200 and
         Playout.valid_options?(playback, init.limits.audio_queue_bytes, options),
       do: GenServer.start_link(__MODULE__, {init, options}),
       else: Error.tuple(:invalid_argument, "Invalid native capacity or playback buffer")
  end

  @doc "Discover device IDs and native formats for a CPAL host."
  def devices(host \\ default_host()),
    do: Native.call(fn -> Device.devices(host) |> Native.unwrap!() end)

  @doc "Queue and callback counters; rendered frames are not confirmed playback."
  def observations(pid), do: Adapter.call(pid, :observations)

  @impl true
  def release_output_recovery(pid, epoch),
    do: Adapter.call(pid, {:release_output_recovery, epoch})

  @impl true
  def init({init, options}) do
    if init.audio_format == %AudioFormat{} do
      {:ok, %{init: init, options: options, status: :starting}, {:continue, :open}}
    else
      {:stop, Error.new(:unsupported, "LocalAudio requires mono PCM16LE at 24 kHz")}
    end
  end

  @impl true
  def handle_continue(:open, state) do
    case Native.call(fn -> open(state) end) do
      {:ok, next} ->
        Event.emit(next.init, :channel, :ready, %{
          capabilities: capabilities(),
          format: next.init.audio_format
        })

        send(self(), :tick)
        {:noreply, next}

      {:error, error} ->
        Event.emit(state.init, :channel, :failed, %{error: error})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:close, id, _reason}, _from, state) do
    unless state.status in [:closing, :closed], do: send(self(), {:close, id})
    {:reply, :ok, %{state | status: :closing}}
  end

  def handle_call(_command, _from, %{status: status} = state) when status != :ready do
    code = if status == :starting, do: :not_ready, else: :closed
    {:reply, Error.tuple(code, "Local audio is not ready"), state}
  end

  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, capabilities()}, state}

  def handle_call({:release_output_recovery, epoch}, _from, %{epoch: epoch} = state),
    do: {:reply, :ok, %{state | playout: Playout.release_recovery(state.playout)}}

  def handle_call({:release_output_recovery, _epoch}, _from, state), do: {:reply, :ok, state}

  def handle_call({:arm_output_space, writer, reference, bytes, epoch}, _from, state)
      when is_pid(writer) and is_reference(reference) and is_integer(bytes) and bytes > 0,
      do: {:reply, :ok, OutputSpace.arm(state, writer, reference, bytes, epoch)}

  def handle_call(:observations, _from, state),
    do:
      {:reply,
       Device.stats(state.device)
       |> Native.unwrap!()
       |> Map.put(:max_poll_gap_us, state.max_poll_gap_us)
       |> Map.put(:input_ppm, state.clock.input_ppm)
       |> Map.put(:output_ppm, state.clock.output_ppm)
       |> Map.put(:playback_starvations, state.playout.starvations)
       |> Map.put(:playback_silence_bytes, state.playout.silence_bytes)
       |> Map.put(:playback_source_bytes, state.playout.source_bytes)
       |> Map.merge(Playout.snapshot(state.playout))
       |> Map.merge(state.timings), state}

  def handle_call({:read, budget}, _from, state), do: AudioQueue.reply_read(state, budget)

  def handle_call({:write, frame}, _from, state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         :ok <- valid_epoch(frame, state.epoch) do
      enqueue(state, frame)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:control, id, control}, _from, state) do
    CommandLog.run(state, id, control, &control_result/3)
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:invalid_argument, "Invalid audio command"), state}

  @impl true
  def handle_info(:tick, %{status: :ready} = state) do
    now = System.monotonic_time(:microsecond)

    state = %{
      state
      | last_poll_us: now,
        poll_gap_us: now - state.last_poll_us,
        max_poll_gap_us: max(state.max_poll_gap_us, now - state.last_poll_us)
    }

    case Native.call(fn ->
           state
           |> timed(&capture/1, :capture_us)
           |> timed(&playback/1, :playback_us)
           |> timed(&observe/1, :observe_us)
         end) do
      {:ok, next} ->
        poll_telemetry(next)
        Process.send_after(self(), :tick, 5)
        {:noreply, next}

      {:error, error} ->
        Event.emit(state.init, :channel, :failed, %{error: error})
        {:stop, :normal, state}
    end
  end

  def handle_info({:close, id}, state) do
    result = Native.call(fn -> cleanup(state) end)
    Event.emit(state.init, :channel, :closed, %{cleanup: result}, command_id: id)
    {:noreply, %{state | status: :closed}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Native.call(fn -> cleanup(state) end)

  defp timed(state, function, key) do
    {elapsed, next} = :timer.tc(fn -> function.(state) end)

    %{
      next
      | timings: Map.update!(next.timings, key, &max(&1, elapsed)),
        last_timings: Map.put(next.last_timings, key, elapsed)
    }
  end

  defp open(state) do
    capacity = Keyword.get(state.options, :native_capacity_frames, 4_800)
    {:ok, device} = open_device(state.options, capacity)
    stats = Device.stats(device) |> Native.unwrap!()

    if capacity < div(stats.output_rate, 50) do
      Device.close(device) |> Native.unwrap!()
      raise ArgumentError, "Native capacity must hold 20 ms of output"
    end

    input_converter = AudioConverter.new(stats.input_rate, 24_000, stats.input_channels, 1)
    output_converter = AudioConverter.new(24_000, stats.output_rate, 1, stats.output_channels)

    Map.merge(state, %{
      device: device,
      input_converter: input_converter,
      output_converter: output_converter,
      status: :ready,
      input_pcm: <<>>,
      output_pcm: <<>>,
      output_waiter: nil,
      epoch: 0,
      sequence: 0,
      suppressed: false,
      playout:
        Playout.new(
          Keyword.get(state.options, :playback_buffer_ms, 120),
          state.init.limits.audio_queue_bytes,
          Keyword.put_new(state.options, :playback_buffering, :adaptive)
        ),
      inbound: %AudioQueue{capacity: state.init.limits.audio_queue_bytes},
      outbound: %AudioQueue{capacity: state.init.limits.audio_queue_bytes},
      stats: stats,
      native_capacity: capacity,
      last_poll_us: System.monotonic_time(:microsecond),
      max_poll_gap_us: 0,
      poll_gap_us: 0,
      last_timings: %{capture_us: 0, playback_us: 0, observe_us: 0},
      timings: %{capture_us: 0, playback_us: 0, observe_us: 0},
      clock: %AudioClock{},
      commands: %CommandLog{limit: state.init.limits.max_records}
    })
  end

  defp open_device(options, capacity) do
    if Keyword.get(options, :device) == :synthetic do
      Device.open_test(capacity) |> Native.unwrap!()
    else
      host = Keyword.get(options, :host, default_host())
      devices = Device.devices(host) |> Native.unwrap!()
      input = Keyword.get_lazy(options, :input_device, fn -> selected_id(devices, :input) end)
      output = Keyword.get_lazy(options, :output_device, fn -> selected_id(devices, :output) end)
      Device.open(host, input, output, capacity) |> Native.unwrap!()
    end
  end

  defp selected_id(devices, direction) do
    default_key = if direction == :input, do: :default_input, else: :default_output

    selected =
      Enum.find(devices, &Map.get(&1, default_key, false)) ||
        Enum.find(devices, &(Map.fetch!(&1, direction) != nil))

    case selected do
      nil -> raise ArgumentError, "No audio device available"
      device -> device.id
    end
  end

  defp default_host do
    case :os.type() do
      {:unix, :darwin} -> "CoreAudio"
      _linux -> "PulseAudio"
    end
  end

  defp capabilities, do: %{Capabilities.buffered_pcm() | output_pacing: :channel}

  defp enqueue(%{suppressed: true} = state, _frame), do: {:reply, :ok, state}

  defp enqueue(state, frame) do
    case AudioQueue.push(state.outbound, frame) do
      {:ok, queue} ->
        Event.emit(state.init, :channel, :playback_observed, %{
          stage: :queued,
          evidence: :queue,
          stream_id: frame.stream_id,
          sequence: frame.sequence,
          epoch: state.epoch
        })

        {:reply, :ok, %{state | outbound: queue, playout: Playout.observe(state.playout, frame)}}

      error ->
        {:reply, error, state}
    end
  end

  defp valid_epoch(%{playback_epoch: epoch}, epoch), do: :ok
  defp valid_epoch(_frame, _epoch), do: Error.tuple(:invalid_argument, "Stale playback epoch")

  defp control_result(state, id, control) do
    case Native.call(fn -> apply_control(state, control) end) do
      {:ok, {:ok, next, payload}} ->
        Event.emit(state.init, :channel, :control_completed, payload, command_id: id)
        {:reply, :ok, next}

      {:ok, {:error, error}} ->
        {:reply, {:error, error}, state}

      {:error, error} ->
        Event.emit(state.init, :channel, :control_failed, %{error: error}, command_id: id)
        Event.emit(state.init, :channel, :failed, %{error: error})
        send(self(), {:close, id})
        {:reply, {:error, error}, %{state | status: :closing}}
    end
  end

  defp apply_control(state, {:suppress_output, flag}) when is_boolean(flag),
    do:
      {:ok,
       %{
         state
         | suppressed: flag,
           output_waiter: nil,
           playout: Playout.reset_timing(state.playout)
       }, %{control: :suppress_output, suppressed: flag}}

  defp apply_control(state, {:clear_output, epoch})
       when is_integer(epoch) and epoch > state.epoch do
    converter = AudioConverter.reset(state.output_converter)
    count = Device.clear(state.device, epoch) |> Native.unwrap!()

    next = %{
      state
      | outbound: AudioQueue.clear(state.outbound),
        output_pcm: <<>>,
        output_waiter: nil,
        output_converter: converter,
        playout: Playout.reset(state.playout),
        epoch: epoch
    }

    {:ok, next,
     %{
       control: :clear_output,
       scope: :parlora_buffers,
       epoch: epoch,
       native_frames_cleared: count
     }}
  end

  defp apply_control(_state, _control),
    do: Error.tuple(:unsupported, "Unsupported playback control")

  defp capture(state) do
    {:ok, pcm, _frames} =
      Device.read(state.device, min(state.native_capacity, div(state.stats.input_rate, 50)))
      |> Native.unwrap!()

    {converted, converter} = AudioConverter.convert(state.input_converter, pcm)
    frame_input(%{state | input_converter: converter, input_pcm: state.input_pcm <> converted})
  end

  defp frame_input(%{input_pcm: <<pcm::binary-size(480), rest::binary>>} = state) do
    frame =
      AudioFrame.pcm(pcm, state.init.adapter_id, state.sequence,
        generation: state.init.generation,
        clock: :local_monotonic,
        timestamp_us: System.monotonic_time(:microsecond)
      )

    state = %{state | input_pcm: rest, sequence: state.sequence + 1}

    case AudioQueue.push(state.inbound, frame) do
      {:ok, queue} ->
        frame_input(%{state | inbound: queue})

      {:error, _error} ->
        Event.emit(state.init, :channel, :audio_discontinuity, %{
          cause: :capture_overflow,
          dropped_us: 10_000
        })

        frame_input(state)
    end
  end

  defp frame_input(state), do: state

  defp playback(state) do
    stats = Device.stats(state.device) |> Native.unwrap!()
    target = div(stats.output_rate * Keyword.get(state.options, :target_buffer_ms, 30), 1_000)

    if stats.output_queued < min(target, state.native_capacity),
      do: fill_output(state),
      else: state
  end

  defp fill_output(%{output_pcm: <<>>} = state) do
    {pcm, queue, playout} =
      Playout.take(
        state.playout,
        state.outbound,
        state.init.limits.max_frame_bytes,
        System.monotonic_time(:microsecond)
      )

    if playout.starvations > state.playout.starvations do
      Event.emit(state.init, :channel, :audio_discontinuity, %{
        cause: :playback_starved,
        epoch: state.epoch,
        suppressed: state.suppressed,
        playback_buffer_ms: playout.buffer_ms,
        recovery_buffer_ms: div(Playout.recovery_wait_us(playout), 1_000)
      })
    end

    :telemetry.execute(
      [:parlora, :audio, :playout],
      %{
        at_us: System.monotonic_time(:microsecond),
        source_bytes: playout.source_bytes - state.playout.source_bytes,
        silence_bytes: playout.silence_bytes - state.playout.silence_bytes,
        peak_sample: peak_sample(pcm),
        queue_bytes: queue.bytes
      },
      %{session_id: state.init.session_id, channel: :local_audio, epoch: state.epoch}
    )

    {output, converter} = AudioConverter.convert(state.output_converter, pcm)

    flush_output(
      OutputSpace.notify(%{
        state
        | outbound: queue,
          output_converter: converter,
          output_pcm: output,
          playout: playout
      })
    )
  end

  defp fill_output(state), do: flush_output(state)

  defp peak_sample(pcm) do
    for <<sample::signed-little-16 <- pcm>>, reduce: 0 do
      peak -> max(peak, abs(sample))
    end
  end

  defp flush_output(%{output_pcm: <<>>} = state), do: state

  defp flush_output(state) do
    {:ok, written} = Device.write(state.device, state.output_pcm, state.epoch) |> Native.unwrap!()
    bytes = written * state.stats.output_channels * 2
    <<_written::binary-size(^bytes), rest::binary>> = state.output_pcm
    %{state | output_pcm: rest}
  end

  defp observe(state) do
    stats = Device.stats(state.device) |> Native.unwrap!()
    if stats.errors > state.stats.errors, do: raise(ErlangError, original: :device_failed)

    if stats.dropped > state.stats.dropped do
      Event.emit(
        state.init,
        :channel,
        :audio_discontinuity,
        Map.merge(poll_evidence(state, stats), %{
          cause: :device_capture_overflow,
          frames: stats.dropped - state.stats.dropped
        })
      )
    end

    if stats.underrun > state.stats.underrun do
      Event.emit(
        state.init,
        :channel,
        :audio_discontinuity,
        Map.merge(poll_evidence(state, stats), %{
          cause: :device_output_underrun,
          frames: stats.underrun - state.stats.underrun
        })
      )
    end

    if stats.handed_off > state.stats.handed_off do
      Event.emit(state.init, :channel, :playback_observed, %{
        stage: :handed_off,
        evidence: :handoff,
        epoch: stats.observed_epoch,
        first_sample: state.stats.handed_off,
        end_sample: stats.handed_off
      })
    end

    {adjustment, clock} =
      AudioClock.sample(state.clock, stats, System.monotonic_time(:microsecond))

    if adjustment != nil do
      {input_ppm, output_ppm} = adjustment
      :ok = Resampler.adjust(state.input_converter.resource, input_ppm) |> Native.unwrap!()
      :ok = Resampler.adjust(state.output_converter.resource, output_ppm) |> Native.unwrap!()

      Event.emit(state.init, :channel, :extension, %{
        namespace: :local_audio,
        input_ppm: input_ppm,
        output_ppm: output_ppm
      })
    end

    %{state | stats: stats, clock: clock}
  end

  defp poll_evidence(state, stats) do
    %{
      poll_gap_us: state.poll_gap_us,
      last_capture_us: state.last_timings.capture_us,
      last_playback_us: state.last_timings.playback_us,
      input_rate: stats.input_rate,
      output_rate: stats.output_rate,
      input_queue_frames: stats.input_queued,
      output_queue_frames: stats.output_queued
    }
  end

  defp poll_telemetry(state) do
    :telemetry.execute(
      [:parlora, :audio, :poll],
      state.timings
      |> Map.merge(poll_evidence(state, state.stats))
      |> Map.merge(%{
        last_observe_us: state.last_timings.observe_us,
        capture_dropped_frames: state.stats.dropped,
        output_underrun_frames: state.stats.underrun
      }),
      %{
        adapter: :local_audio,
        adapter_id: state.init.adapter_id,
        session_id: state.init.session_id
      }
    )
  end

  defp cleanup(%{device: device} = state) do
    Device.close(device) |> Native.unwrap!()
    AudioConverter.close(state.input_converter)
    AudioConverter.close(state.output_converter)
  end

  defp cleanup(_state), do: :ok
end
