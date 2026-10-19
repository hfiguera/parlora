defmodule Parlora.Providers.Gemini do
  @moduledoc """
  Gemini 3.8 Live with application-owned credentials and backend work.

  Speakable context is sent as a function response or an application content turn.
  A content turn triggers a response and may interrupt active model generation.
  Submission is reported as unconfirmed, never as a remote acknowledgment.
  Quiet context and live system-instruction changes are unsupported.
  """
  use GenServer
  use Parlora.ProviderClient, protocol: Parlora.Providers.Gemini.Protocol
  alias Parlora.{Adapter, AudioFormat, AudioFrame, AudioQueue, CommandLog, Error, Event, Pacer}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.Gemini.{Audio, Calls, Connection, Protocol, ResponseWatch}

  @doc "Finite session limits for generated audio bursts; pass as session :limits, with optional overrides."
  @impl true
  def audio_limits(format \\ %AudioFormat{}), do: OutputBuffer.burst_limits(format)

  @impl true
  def resume_output(pid, token), do: Adapter.call(pid, {:resume_output, token})
  @impl true
  def resolve_delegation(pid, id, outcome),
    do: Adapter.call(pid, {:resolve_delegation, id, outcome})

  @impl true
  def init({init, options, config}) do
    state = %{
      init: init,
      key: Keyword.fetch!(options, :api_key),
      version: Keyword.get(options, :api_version, :v1beta),
      setup: config.setup,
      history: config.history,
      socket: nil,
      connector: &Connection.connect/2,
      status: :connecting,
      ever_ready: false,
      connection_epoch: 0,
      reconnects: 0,
      resume_handle: nil,
      resumable: false,
      go_away: false,
      activity: :unknown,
      speech: :idle,
      response_watch: nil,
      response_timeout_ms: Keyword.get(options, :response_timeout_ms, 12_000),
      inbound: OutputBuffer.new(init.limits),
      outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
      audio: Audio.new(init.audio_format),
      waiter: nil,
      interruption: 0,
      output_blocked: false,
      muted: false,
      commands: %CommandLog{limit: init.limits.max_records},
      calls: Calls.new(init.limits.max_records),
      sequence: 0,
      caption_id: nil,
      usage: nil,
      usage_reports: 0,
      deadline: now()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: %{status: status.state.status}, message: :redacted})

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call({:close, _id, reason}, _from, state),
    do: {:reply, :ok, finish(state, reason)}

  def handle_call(_command, _from, %{status: :closed} = state),
    do: {:reply, Error.tuple(:closed, "Provider is closed"), state}

  def handle_call(:capabilities, _from, state),
    do: {:reply, {:ok, Protocol.capabilities()}, state}

  def handle_call({:resume_output, token}, _from, state) do
    next = if token == state.interruption, do: %{state | output_blocked: false}, else: state
    {:reply, :ok, notify(next)}
  end

  def handle_call(:output_buffer_status, _from, state),
    do:
      {:reply,
       {:ok, %{queued_bytes: state.inbound.bytes, capacity_bytes: state.inbound.capacity}}, state}

  def handle_call({:arm_output_ready, reader, reference}, _from, state)
      when is_pid(reader) and is_reference(reference),
      do: {:reply, :ok, notify(%{state | waiter: {reader, reference}})}

  def handle_call({:read, _budget}, _from, %{output_blocked: true} = state),
    do: {:reply, {:ok, []}, state}

  def handle_call({:read, budget}, _from, state) do
    case OutputBuffer.read(state.inbound, budget, state.init.limits, now(), state.init) do
      {:ok, frames, queue} ->
        {:reply, {:ok, frames},
         %{state | inbound: queue, waiter: if(frames == [], do: state.waiter)}}

      {:error, %Error{code: :output_stale} = error} ->
        {:reply, {:error, error}, fail(state, :output_stale)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _from, state) do
    case AudioFrame.validate(frame, state.init.audio_format, state.init.limits) do
      :ok -> accept_audio(state, frame)
      error -> {:reply, error, state}
    end
  end

  def handle_call(_command, _from, %{status: status} = state) when status != :ready,
    do: {:reply, Error.tuple(:not_ready, "Provider connection is not ready"), state}

  def handle_call({:append, update}, _from, state) do
    case Protocol.validate_update(update, state.init.generation) do
      :ok -> CommandLog.run(state, update.id, {:context, update}, &append_context_command/3)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resolve_delegation, id, outcome}, _from, state) when is_map(outcome) do
    case Calls.complete(state.calls, id, outcome) do
      {:ok, command, calls} ->
        next = transmit(%{state | calls: calls, activity: :unknown}, command)
        next = ResponseWatch.submitted(next, command)

        {:reply,
         if(next.status == :closed, do: Error.tuple(:closed, "Provider closed"), else: :ok), next}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:control, id, {:input_muted, flag} = command}, _from, state)
      when is_boolean(flag) do
    CommandLog.run(state, id, command, fn state, id, _command ->
      next = %{
        state
        | muted: flag,
          outbound: AudioQueue.clear(state.outbound),
          audio: Audio.reset_input(state.audio)
      }

      emit(next, :control_completed, %{muted: flag, scope: :local_input_gate}, id)
      {:reply, :ok, next}
    end)
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:unsupported, "Unsupported Gemini command"), state}

  @impl true
  def handle_info({:gemini_response_deadline, token}, state),
    do: {:noreply, ResponseWatch.expire(state, token)}

  def handle_info(:send_audio, %{status: :closed} = state), do: {:noreply, state}

  def handle_info(:send_audio, state) do
    next = if state.status == :ready, do: send_audio(state), else: state
    {deadline, delay} = Pacer.next(next.deadline, 20_000)
    Process.send_after(self(), :send_audio, delay)
    {:noreply, %{next | deadline: deadline}}
  end

  def handle_info({:startup_timeout, epoch}, %{connection_epoch: epoch, status: status} = state)
      when status in [:connecting, :starting], do: {:noreply, fail(state, :startup_timeout)}

  def handle_info({:startup_timeout, _epoch}, state), do: {:noreply, state}

  def handle_info(
        {:reconnect, epoch},
        %{connection_epoch: epoch, status: :reconnecting} = state
      ),
      do: {:noreply, connect(state)}

  def handle_info({:reconnect, _epoch}, state), do: {:noreply, state}

  def handle_info(
        {:interruption_timeout, token},
        %{interruption: token, output_blocked: true} = state
      ),
      do: {:noreply, fail(state, :interruption_not_cleared)}

  def handle_info({:interruption_timeout, _token}, state), do: {:noreply, state}

  def handle_info({:go_away_deadline, epoch}, %{connection_epoch: epoch, go_away: true} = state),
    do: {:noreply, reconnect_or_fail(state, :resumption_unsafe)}

  def handle_info({:go_away_deadline, _epoch}, state), do: {:noreply, state}
  def handle_info(_message, %{socket: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case Connection.receive(state.socket, message) do
      {:ok, socket, frames} ->
        {:noreply, Enum.reduce(frames, %{state | socket: socket}, &frame/2)}

      {:error, reason} ->
        {:noreply, reconnect_or_fail(state, reason)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Connection.close(state.socket)
    Audio.close(state.audio)
    :ok
  end

  defp accept_audio(%{status: :ready, muted: false} = state, frame) do
    case AudioQueue.push(state.outbound, frame) do
      {:ok, queue} -> {:reply, :ok, %{state | outbound: queue}}
      error -> {:reply, error, state}
    end
  end

  # Input during reconnect or mute is discarded, never replayed.
  defp accept_audio(state, _frame), do: {:reply, :ok, state}

  defp append_context_command(state, id, {:context, update}) do
    case Calls.context(state.calls, update.delegation_id, update.content) do
      {:ok, command, calls} ->
        next = transmit(%{state | calls: calls, activity: :unknown}, command)

        next =
          if next.status == :ready, do: ResponseWatch.arm(next, :context_submitted), else: next

        context_outcome(next, id)

      error ->
        {:reply, error, state}
    end
  end

  defp context_outcome(%{status: :closed} = state, _id),
    do:
      {:reply,
       {:error,
        Error.new(:closed, "Context transmission outcome is unknown", %{outcome: :unknown})},
       state}

  defp context_outcome(state, id) do
    emit(state, :context_submitted, %{outcome: :unconfirmed, evidence: :socket_write}, id)
    {:reply, :ok, state}
  end

  defp connect(state) do
    Process.send_after(
      self(),
      {:startup_timeout, state.connection_epoch},
      state.init.limits.startup_timeout_ms
    )

    case state.connector.(state.key, state.version) do
      {:ok, socket} -> %{state | socket: socket, status: :connecting}
      {:error, reason} -> fail(state, reason)
    end
  end

  defp frame(_frame, %{status: :closed} = state), do: state

  defp frame(:open, state) do
    setup =
      if state.ever_ready,
        do: %{
          state.setup
          | sessionResumption: %{handle: state.resume_handle},
            historyConfig: %{initialHistoryInClientContent: false}
        },
        else: state.setup

    transmit(%{state | status: :starting}, %{setup: setup})
  end

  defp frame({kind, json}, state) when kind in [:text, :binary] do
    case JSON.decode(json) do
      {:ok, event} -> Enum.reduce(Protocol.events(event), state, &event/2)
      _invalid -> fail(state, :invalid_json)
    end
  end

  defp frame({:ping, data}, state), do: wire(state, {:pong, data})
  defp frame({:close, _code, _reason}, state), do: reconnect_or_fail(state, :socket_closed)
  defp frame({:error, _error}, state), do: fail(state, :malformed_frame)
  defp frame(_frame, state), do: state

  defp event(_event, %{status: :closed} = state), do: state

  defp event(:ready, %{status: :starting} = state) do
    next = %{
      state
      | status: :ready,
        ever_ready: true,
        activity: :unknown,
        caption_id: nil,
        deadline: now()
    }

    if state.ever_ready do
      emit(next, :provider_connection, %{
        state: :resumed,
        connection_epoch: state.connection_epoch,
        evidence: :setup_complete,
        continuity: :unverified
      })

      next
    else
      next =
        if state.history == [],
          do: next,
          else: transmit(next, %{clientContent: %{turns: state.history, turnComplete: true}})

      if next.status != :closed do
        emit(next, :ready, %{
          capabilities: Protocol.capabilities(),
          format: state.init.audio_format
        })

        send(self(), :send_audio)
      end

      next
    end
  end

  defp event(:interrupted, state), do: interrupt(state)

  defp event({:transcript, %{speaker: :assistant} = transcript}, state) do
    state = state |> ResponseWatch.clear(:progress_observed) |> speech(:speaking)
    id = state.caption_id || Parlora.ID.new()
    emit(state, :transcript_delta, Map.put(transcript, :segment_id, id))
    %{state | activity: :unknown, caption_id: id}
  end

  defp event({:transcript, transcript}, state) do
    emit(state, :transcript_delta, transcript)

    state =
      if String.trim(transcript.delta) == "",
        do: state,
        else: ResponseWatch.arm(state, :caller_caption)

    %{state | activity: :unknown}
  end

  # Generation/utterance boundaries separate caption groups, not playback or jobs.
  defp event(:generation_complete, state),
    do: %{state | caption_id: nil}

  defp event(:utterance_complete, state),
    do: speech(%{state | caption_id: nil}, :idle)

  defp event({:audio, %{"data" => encoded, "mimeType" => mime}}, state)
       when mime in ["audio/pcm;rate=24000", "audio/pcm;rate=24000;channels=1"] do
    state = state |> ResponseWatch.clear(:progress_observed) |> speech(:speaking)

    with {:ok, pcm} <- Base.decode64(encoded),
         true <- rem(byte_size(pcm), 2) == 0 do
      {bytes, audio} = Audio.output(state.audio, pcm)

      case OutputBuffer.push(state.inbound, bytes, state.init, state.sequence, now()) do
        {:ok, {queue, sequence}} ->
          notify(%{
            state
            | inbound: queue,
              sequence: sequence,
              audio: audio,
              activity: :in_progress
          })

        {:error, error} ->
          fail(%{state | audio: audio}, error.code)
      end
    else
      _invalid -> fail(state, :invalid_audio)
    end
  end

  defp event({:audio, _invalid}, state), do: fail(state, :invalid_audio_format)

  defp event({:call, call}, state) do
    case Calls.admit(state.calls, call) do
      {:new, calls} ->
        # A tool call is not a reply to the caller. The application may
        # associate this new call ID with work whose result is already pending.

        emit(state, :delegation_requested, %{
          id: call["id"],
          target: :client,
          offset_ms: nil,
          arguments: call["args"]
        })

        %{state | calls: calls, activity: :in_progress}

      {:duplicate, _calls} ->
        state

      {:error, error} ->
        fail(state, error.code)
    end
  end

  defp event({:cancel_call, id}, state) do
    case Calls.cancel(state.calls, id) do
      {:cancelled, calls} ->
        emit(state, :delegation_cancelled, %{id: id, reason: :provider_cancelled})
        %{state | calls: calls}

      {:unchanged, _calls} ->
        state
    end
  end

  defp event({:activity, activity}, state) do
    emit(state, :provider_activity, %{state: activity})
    maybe_resume(%{state | activity: activity})
  end

  defp event({:usage, usage}, state) do
    # Preserve each provider report rather than assuming its counters are deltas
    # or cumulative billing. A local close never makes the last report final.
    report = %{
      unit: :tokens,
      scope: :provider_report,
      values: usage,
      report: state.usage_reports + 1,
      final?: false
    }

    emit(state, :usage_updated, report)
    %{state | usage: report, usage_reports: report.report}
  end

  defp event({:resumption, update}, state) do
    handle = update["newHandle"]
    resumable = update["resumable"] == true and is_binary(handle) and handle != ""
    maybe_resume(%{state | resumable: resumable, resume_handle: if(resumable, do: handle)})
  end

  defp event({:go_away, notice}, state) do
    delay = go_away_delay(notice["timeLeft"])
    Process.send_after(self(), {:go_away_deadline, state.connection_epoch}, delay)
    maybe_resume(%{state | go_away: true})
  end

  defp event({:error, _error}, state), do: fail(state, :provider_rejected)
  defp event(_lifecycle, state), do: state

  defp interrupt(state) do
    state = speech(state, :idle)
    token = state.interruption + 1
    emit(state, :output_interrupted, %{token: token})

    Process.send_after(
      self(),
      {:interruption_timeout, token},
      state.init.limits.cancellation_timeout_ms
    )

    %{
      state
      | interruption: token,
        output_blocked: true,
        inbound: AudioQueue.clear(state.inbound),
        audio: Audio.reset_output(state.audio),
        waiter: nil
    }
  end

  # Provider utterance state is separate from background interaction and from
  # downstream playback. generationComplete alone does not end an utterance.
  defp speech(%{speech: value} = state, value), do: state

  defp speech(state, value) do
    emit(state, :provider_speech, %{state: value})
    %{state | speech: value}
  end

  defp send_audio(state) do
    size = AudioFormat.bytes_for_ms(state.init.audio_format, 20)
    {data, queue} = AudioQueue.take_bytes(state.outbound, size)
    silence = AudioFormat.silence(state.init.audio_format, 20)
    pcm = data <> binary_part(silence, 0, size - byte_size(data))
    {bytes, audio} = Audio.input(state.audio, pcm)
    next = %{state | outbound: queue, audio: audio}
    if bytes == <<>>, do: next, else: transmit(next, Protocol.audio(bytes, 16_000))
  end

  defp notify(state), do: OutputBuffer.notify(state)

  defp maybe_resume(%{go_away: true} = state),
    do: if(safe_resume?(state), do: reconnect(state), else: state)

  defp maybe_resume(state), do: state

  defp safe_resume?(state),
    do:
      state.ever_ready and state.resumable and state.activity == :idle and
        not Calls.pending?(state.calls) and state.reconnects < 2

  defp reconnect_or_fail(state, reason),
    do: if(safe_resume?(state), do: reconnect(state), else: fail(state, reason))

  defp reconnect(state) do
    state = ResponseWatch.clear(state, :connection_changed)
    Connection.close(state.socket)
    epoch = state.connection_epoch + 1
    Process.send_after(self(), {:reconnect, epoch}, 2_000)

    emit(state, :provider_connection, %{
      state: :reconnecting,
      input_during_reconnect: :discarded,
      retry_delay_ms: 2_000
    })

    %{
      state
      | socket: nil,
        status: :reconnecting,
        connection_epoch: epoch,
        reconnects: state.reconnects + 1,
        go_away: false,
        outbound: AudioQueue.clear(state.outbound),
        audio: Audio.reset_input(state.audio)
    }
  end

  defp go_away_delay(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, "s"} when seconds > 0 -> max(1, min(60_000, trunc(seconds * 1_000) - 500))
      _invalid -> 1
    end
  end

  defp go_away_delay(_value), do: 1
  defp transmit(state, command), do: wire(state, {:text, JSON.encode!(command)})

  defp wire(state, frame) do
    case Connection.send(state.socket, frame) do
      {:ok, socket} -> %{state | socket: socket}
      {:error, reason} -> fail(state, reason)
    end
  end

  defp emit(state, type, payload, command_id \\ nil),
    do: Event.emit(state.init, :provider, type, payload, command_id: command_id)

  defp fail(%{status: :closed} = state, _reason), do: state

  defp fail(state, reason) do
    emit(state, :failed, %{
      error: Error.new(:adapter_failed, "Gemini provider failed", %{reason: reason})
    })

    finish(state, reason)
  end

  defp finish(%{status: :closed} = state, _reason), do: state

  defp finish(state, reason) do
    state = ResponseWatch.clear(state, :closed)
    Connection.close(state.socket)
    emit(state, :closed, %{reason: reason, finalized?: false, usage: state.usage})

    %{
      state
      | status: :closed,
        socket: nil,
        key: nil,
        resume_handle: nil,
        waiter: nil,
        inbound: AudioQueue.clear(state.inbound),
        outbound: AudioQueue.clear(state.outbound)
    }
  end

  defp now, do: System.monotonic_time(:microsecond)
end
