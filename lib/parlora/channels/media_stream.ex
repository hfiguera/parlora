defmodule Parlora.Channels.MediaStream do
  @moduledoc false
  use GenServer
  alias Parlora.{Adapter, AudioFormat, AudioFrame, AudioQueue, CommandLog, Error, Event, Pacer}
  alias Parlora.Channel.Capabilities
  alias Parlora.Channels.MediaStream.{Packetizer, Playback}

  def start_link(init, options, protocol_module) do
    settings = %{
      max_age_ms: Keyword.get(options, :max_age_ms, 200),
      mark_timeout_ms: Keyword.get(options, :mark_timeout_ms, 2_000),
      max_inflight_ms: Keyword.get(options, :max_inflight_ms, 500)
    }

    if valid_options?(init, options, settings, protocol_module),
      do: GenServer.start_link(__MODULE__, {init, options, settings, protocol_module}),
      else:
        Error.tuple(
          :invalid_argument,
          "Media stream requires an owner, call identity, μ-law and finite bounds"
        )
  end

  @doc "Admit a Media stream message from the authenticated transport owner."
  def receive_message(pid, message), do: Adapter.call(pid, {:receive, message})

  @doc "Pull a paced batch of wire messages from the transport owner."
  def pull(pid), do: Adapter.call(pid, :pull)

  @impl true
  def init({init, options, settings, protocol_module}) do
    owner = Keyword.fetch!(options, :transport)
    Process.monitor(owner)
    Process.send_after(self(), :startup_timeout, init.limits.startup_timeout_ms)
    Process.send_after(self(), :watchdog, 100)
    send(owner, {protocol_module.owner_tag(), self(), :attached})

    {:ok,
     %{
       init: init,
       owner: owner,
       settings: settings,
       status: :starting,
       protocol_module: protocol_module,
       protocol: protocol_module.init(options, init.limits),
       inbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       playback: %Playback{
         capacity: AudioFormat.bytes_for_ms(init.audio_format, settings.max_inflight_ms),
         boundary: protocol_module.mark_boundary()
       },
       commands: %CommandLog{limit: init.limits.max_records},
       sequence: 0,
       epoch: 0,
       suppressed: false,
       next_send_us: nil,
       discontinuities: 0,
       last_notice_us: nil
     }}
  end

  @impl true
  def handle_call({:close, id, _reason}, _from, state),
    do: {:reply, :ok, finish(state, :local_close, id)}

  def handle_call(_command, _from, %{status: :closed} = state),
    do: {:reply, Error.tuple(:closed, "Media stream is closed"), state}

  def handle_call({:receive, message}, {owner, _tag}, %{owner: owner} = state) do
    case state.protocol_module.receive_message(state.protocol, message) do
      {:ok, event, protocol} -> receive_event(%{state | protocol: protocol}, event)
      {:duplicate, _protocol} -> {:reply, :ok, state}
      {:error, error} -> {:reply, {:error, error}, fail(state, error)}
    end
  end

  def handle_call(_command, _from, %{status: :starting} = state),
    do: {:reply, Error.tuple(:not_ready, "Media stream start has not been validated"), state}

  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, capabilities()}, state}

  def handle_call({:read, budget}, _from, state) do
    state = flush_input(state) |> discard_expired_input()
    AudioQueue.reply_read(state, budget)
  end

  def handle_call({:write, frame}, _from, state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         true <- frame.playback_epoch == state.epoch do
      admit_output(state, frame)
    else
      false -> {:reply, Error.tuple(:invalid_argument, "Stale playback epoch"), state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:pull, {owner, _tag}, %{owner: owner} = state), do: output(state, now())

  def handle_call({:control, id, control}, _from, state),
    do: CommandLog.run(state, id, control, &apply_control/3)

  def handle_call(_command, _from, state),
    do:
      {:reply, Error.tuple(:invalid_argument, "Invalid Media stream adapter command or owner"),
       state}

  @impl true
  def handle_info(:startup_timeout, %{status: :starting} = state),
    do: {:noreply, fail(state, Error.new(:timeout, "Media stream startup timed out"))}

  def handle_info(:watchdog, %{status: status} = state) when status != :closed do
    state = discard_expired_output(state)

    if Playback.expired?(state.playback, now(), state.settings.mark_timeout_ms) do
      error =
        Error.new(:timeout, "Media stream playback acknowledgment timed out", %{
          reason: :playback_ack_timeout,
          inflight_bytes: state.playback.bytes,
          pending_marks: map_size(state.playback.pending)
        })

      {:noreply, fail(state, error)}
    else
      Process.send_after(self(), :watchdog, 100)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:noreply, fail(state, Error.new(:closed, "Media stream transport disconnected"))}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.status != :closed,
      do: send(state.owner, {state.protocol_module.owner_tag(), self(), :close})

    :ok
  end

  @impl true
  def format_status(status),
    do:
      Map.merge(status, %{state: Map.take(status.state, [:status, :settings]), message: :redacted})

  defp valid_options?(init, options, settings, protocol_module) do
    init.audio_format == AudioFormat.pcmu() and init.limits.audio_queue_bytes >= 160 and
      settings.max_age_ms >= 20 and settings.max_inflight_ms >= 20 and
      is_pid(Keyword.get(options, :transport)) and
      protocol_module.valid_options?(options) and
      Enum.all?(settings, fn {_key, value} -> is_integer(value) and value in 1..10_000 end)
  end

  defp capabilities do
    %Capabilities{
      input_formats: [AudioFormat.pcmu()],
      output_formats: [AudioFormat.pcmu()],
      full_duplex?: true,
      output_suppression?: true,
      clear_scope: :remote_buffer,
      playback_evidence: [:queue, :handoff, :device_report]
    }
  end

  defp flush_input(state) do
    {events, protocol} = state.protocol_module.flush(state.protocol, now())

    Enum.reduce(events, %{state | protocol: protocol}, fn event, acc ->
      {:reply, :ok, next} = receive_event(acc, event)
      next
    end)
  end

  defp receive_event(state, {:audio_batch, events}) do
    next =
      Enum.reduce(events, state, fn event, acc ->
        {:reply, :ok, next} = receive_event(acc, event)
        next
      end)

    {:reply, :ok, next}
  end

  defp receive_event(state, :connected), do: {:reply, :ok, state}

  defp receive_event(state, :started) do
    Event.emit(state.init, :channel, :ready, %{
      capabilities: capabilities(),
      format: state.init.audio_format
    })

    {:reply, :ok, %{state | status: :ready}}
  end

  defp receive_event(state, {:audio, data, _timestamp_us, discontinuity}) do
    state = if discontinuity, do: discontinuity(state, :input_timestamp_gap), else: state
    {:reply, :ok, capture(state, data, discontinuity)}
  end

  defp receive_event(state, {:mark, name}) do
    case Playback.acknowledge(state.playback, name) do
      {:unknown, _playback} ->
        {:reply, :ok, state}

      {:playback, record, playback} ->
        Event.emit(
          state.init,
          :channel,
          :playback_observed,
          record |> Map.drop([:sent_at_us]) |> Map.put(:ack_latency_us, now() - record.sent_at_us)
        )

        {:reply, :ok, %{state | playback: playback}}

      {:clear, record, playback} ->
        Event.emit(
          state.init,
          :channel,
          :control_completed,
          %{epoch: record.epoch, scope: :remote_buffer},
          command_id: record.command_id
        )

        {:reply, :ok, %{state | playback: playback}}
    end
  end

  defp receive_event(state, :stopped), do: {:reply, :ok, finish(state, :stream_stopped, nil)}
  defp receive_event(state, :dtmf), do: {:reply, :ok, state}

  defp capture(state, <<>>, _discontinuity), do: state

  defp capture(state, data, discontinuity) do
    count = min(byte_size(data), state.init.limits.max_frame_bytes)
    <<part::binary-size(^count), rest::binary>> = data

    frame =
      AudioFrame.new(part, state.init.audio_format, state.init.adapter_id, state.sequence,
        generation: state.init.generation,
        clock: :local_monotonic,
        timestamp_us: now(),
        discontinuity: discontinuity
      )

    case AudioQueue.push(state.inbound, frame) do
      {:ok, queue} ->
        capture(%{state | inbound: queue, sequence: state.sequence + 1}, rest, false)

      {:error, _error} ->
        {_old, queue} = AudioQueue.pop(state.inbound, state.init.limits.max_frame_bytes)
        capture(discontinuity(%{state | inbound: queue}, :input_overflow), data, true)
    end
  end

  defp admit_output(%{suppressed: true} = state, _frame), do: {:reply, :ok, state}

  defp admit_output(state, frame) do
    state = discard_expired_output(state)
    frame = %{frame | timestamp_us: now(), clock: :local_monotonic}

    case AudioQueue.push(state.outbound, frame) do
      {:ok, queue} ->
        observe(%{state | outbound: queue}, frame, :queued, :queue)
        {:reply, :ok, %{state | outbound: queue}}

      error ->
        {:reply, error, state}
    end
  end

  defp output(state, time) when is_integer(state.next_send_us) and time < state.next_send_us,
    do: {:reply, {:ok, [], max(1, div(state.next_send_us - time + 999, 1_000))}, state}

  defp output(state, time), do: next_output(discard_expired_output(state), time)

  defp next_output(state, time) do
    case Packetizer.take(state.outbound, time, state.protocol_module.minimum_packet_bytes()) do
      {:ready, frame, queue} -> send_audio(state, frame, queue, time)
      {:wait, wait} -> {:reply, {:ok, [], wait}, state}
      :empty -> {:reply, {:ok, [], 10}, %{state | next_send_us: nil}}
    end
  end

  defp send_audio(state, frame, queue, time) do
    case Playback.admit(state.playback, frame, time) do
      {:ok, name, playback} ->
        observe(%{state | outbound: queue, playback: playback}, frame, :handed_off, :handoff)

        messages = [
          state.protocol_module.media(
            state.protocol_module.stream_id(state.protocol),
            frame.data
          ),
          state.protocol_module.mark(state.protocol_module.stream_id(state.protocol), name)
        ]

        {deadline, wait} = Pacer.next(state.next_send_us || time, frame.duration_us)

        {:reply, {:ok, messages, wait},
         %{state | outbound: queue, playback: playback, next_send_us: deadline}}

      {:error, _backpressure} ->
        {:reply, {:ok, [], 10}, state}
    end
  end

  defp apply_control(state, id, {:clear_output, epoch})
       when is_integer(epoch) and epoch > state.epoch do
    case Playback.clear(state.playback, id, epoch, now()) do
      {:ok, mark, playback} ->
        messages = [
          state.protocol_module.clear(state.protocol_module.stream_id(state.protocol)),
          state.protocol_module.mark(state.protocol_module.stream_id(state.protocol), mark)
        ]

        send(state.owner, {state.protocol_module.owner_tag(), self(), {:send, messages}})

        Event.emit(state.init, :channel, :playback_observed, %{
          stage: :cleared,
          evidence: :queue,
          epoch: state.epoch,
          bytes: state.outbound.bytes
        })

        {:reply, :ok,
         %{
           state
           | outbound: AudioQueue.clear(state.outbound),
             playback: playback,
             epoch: epoch,
             next_send_us: nil
         }}

      error ->
        {:reply, error, state}
    end
  end

  defp apply_control(state, id, {:suppress_output, flag}) when is_boolean(flag) do
    Event.emit(
      state.init,
      :channel,
      :control_completed,
      %{suppressed: flag, scope: :parlora_buffers},
      command_id: id
    )

    {:reply, :ok, %{state | suppressed: flag, outbound: AudioQueue.clear(state.outbound)}}
  end

  defp apply_control(state, _id, _control),
    do: {:reply, Error.tuple(:unsupported, "Unsupported Media stream control"), state}

  defp observe(state, frame, stage, evidence),
    do:
      Event.emit(state.init, :channel, :playback_observed, %{
        stage: stage,
        evidence: evidence,
        epoch: frame.playback_epoch,
        sequence: frame.sequence,
        boundary: :websocket_owner,
        queued_bytes: state.outbound.bytes,
        inflight_bytes: state.playback.bytes,
        duration_us: frame.duration_us,
        queue_age_us: max(0, now() - frame.timestamp_us)
      })

  defp expired?(queue, state) do
    case :queue.peek(queue.items) do
      {:value, frame} -> now() - frame.timestamp_us >= state.settings.max_age_ms * 1_000
      :empty -> false
    end
  end

  defp discard_expired_input(state) do
    if expired?(state.inbound, state) do
      {_old, queue} = AudioQueue.pop(state.inbound, state.init.limits.max_frame_bytes)
      discard_expired_input(discontinuity(%{state | inbound: queue}, :input_stale))
    else
      state
    end
  end

  defp discard_expired_output(state) do
    cutoff = now() - state.settings.max_age_ms * 1_000
    {queue, bytes, count} = expire_output(state.outbound, cutoff, 0, 0)

    if count > 0 do
      Event.emit(state.init, :channel, :audio_discontinuity, %{
        cause: :output_stale,
        dropped_bytes: bytes,
        dropped_frames: count,
        dropped_duration_us: AudioFormat.duration_us(state.init.audio_format, bytes),
        queued_bytes: queue.bytes,
        inflight_bytes: state.playback.bytes,
        epoch: state.epoch
      })
    end

    %{state | outbound: queue}
  end

  defp expire_output(queue, cutoff, bytes, count) do
    case :queue.out(queue.items) do
      {{:value, frame}, rest} when frame.timestamp_us <= cutoff ->
        size = byte_size(frame.data)
        next = %{queue | items: rest, bytes: queue.bytes - size}
        expire_output(next, cutoff, bytes + size, count + 1)

      _fresh_or_empty ->
        {queue, bytes, count}
    end
  end

  defp discontinuity(state, cause) do
    time = now()
    count = state.discontinuities + 1

    if state.last_notice_us == nil or time - state.last_notice_us >= 250_000 do
      Event.emit(state.init, :channel, :audio_discontinuity, %{cause: cause, total_count: count})
      %{state | discontinuities: count, last_notice_us: time}
    else
      %{state | discontinuities: count}
    end
  end

  defp fail(%{status: :closed} = state, _error), do: state

  defp fail(state, error) do
    Event.emit(state.init, :channel, :failed, %{error: error})
    finish(state, :failed, nil)
  end

  defp finish(%{status: :closed} = state, _reason, _id), do: state

  defp finish(state, reason, id) do
    Enum.each(state.playback.pending, fn {_name, record} ->
      if Map.has_key?(record, :command_id) do
        Event.emit(state.init, :channel, :control_failed, %{outcome: :unknown},
          command_id: record.command_id
        )
      else
        Event.emit(
          state.init,
          :channel,
          :playback_observed,
          Map.merge(record, %{stage: :unknown, cause: :stream_closed})
        )
      end
    end)

    send(state.owner, {state.protocol_module.owner_tag(), self(), :close})

    Event.emit(
      state.init,
      :channel,
      :closed,
      %{reason: reason, scope: :stream, call_ended?: :unknown},
      command_id: id
    )

    %{
      state
      | status: :closed,
        inbound: AudioQueue.clear(state.inbound),
        outbound: AudioQueue.clear(state.outbound),
        playback: %Playback{}
    }
  end

  defp now, do: System.monotonic_time(:microsecond)
end
