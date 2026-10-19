defmodule Parlora.Providers.Grok do
  @moduledoc """
  Grok Voice 3.0 with application-owned backend work over WebSocket.

  Speakable context uses conversation items and explicit response continuation.
  Socket submission is unconfirmed; caller transcripts are finalized per item.
  Quiet/instruction updates, usage reporting and transparent resumption are not
  advertised. Input mute gates local audio while sending codec silence.
  """
  use GenServer
  use Parlora.ProviderClient, protocol: Parlora.Providers.Grok.Protocol
  alias Parlora.{Adapter, AudioFormat, AudioFrame, AudioQueue, CommandLog, Error, Event, Pacer}
  alias Parlora.Provider.{OutputBuffer, WebSocketConnection}
  alias Parlora.Providers.Grok.{Calls, Protocol, Transcripts}

  @doc "Finite receive limits for generated speech bursts, in the selected pipeline format."
  @impl true
  def audio_limits(format \\ %AudioFormat{}), do: OutputBuffer.burst_limits(format, 20_000)

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
      config: config,
      socket: nil,
      status: :connecting,
      commands: %CommandLog{limit: init.limits.max_records},
      calls: Calls.new(init.limits.max_records),
      transcripts: Transcripts.new(init.limits.max_records),
      inbound: OutputBuffer.new(init.limits),
      outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
      sequence: 0,
      waiter: nil,
      muted: false,
      interruption: 0,
      output_blocked: false,
      response: nil,
      request_timer: nil,
      discarded: MapSet.new(),
      caller_speaking: false,
      auto_response_pending: false,
      want_response: MapSet.new(),
      deadline: now()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: %{status: status.state.status}, message: :redacted})

  @impl true
  def handle_continue(:connect, state) do
    Process.send_after(self(), :grok_startup_timeout, state.init.limits.startup_timeout_ms)

    case WebSocketConnection.connect({:https, "api.x.ai", 443}, Protocol.path(), [
           {"authorization", "Bearer " <> state.key}
         ]) do
      {:ok, socket} -> {:noreply, %{state | socket: socket}}
      {:error, reason} -> {:noreply, fail(state, reason)}
    end
  end

  @impl true
  def handle_call({:close, _id, reason}, _from, state), do: {:reply, :ok, close(state, reason)}

  def handle_call(_command, _from, %{status: :closed} = state),
    do: {:reply, Error.tuple(:closed, "Grok provider is closed"), state}

  def handle_call(:capabilities, _from, %{status: :ready} = state),
    do: {:reply, {:ok, Protocol.capabilities()}, state}

  def handle_call({:resume_output, token}, _from, state) do
    next = if token == state.interruption, do: %{state | output_blocked: false}, else: state
    {:reply, :ok, next |> continue_response() |> notify()}
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
        next = %{state | inbound: queue, waiter: if(frames == [], do: state.waiter)}
        {:reply, {:ok, frames}, continue_response(next)}

      {:error, %Error{code: :output_stale} = error} ->
        {:reply, {:error, error}, fail(state, :output_stale)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _from, %{status: :ready, muted: false} = state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         {:ok, queue} <- AudioQueue.push(state.outbound, frame) do
      {:reply, :ok, %{state | outbound: queue}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:write, frame}, _from, %{status: :ready} = state),
    do: {:reply, AudioFrame.validate(frame, state.init.audio_format, state.init.limits), state}

  def handle_call(_command, _from, %{status: status} = state) when status != :ready,
    do:
      {:reply, Error.tuple(:not_ready, "Grok session has not acknowledged configuration"), state}

  def handle_call({:append, update}, _from, state) do
    case Protocol.validate(update, state.init.generation) do
      :ok -> CommandLog.run(state, update.id, {:context, update}, &submit_context/3)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resolve_delegation, id, outcome}, _from, state) when is_map(outcome) do
    case Calls.complete(state.calls, id, outcome) do
      {:ok, command, calls} ->
        next = transmit(%{state | calls: calls}, command)

        next =
          if outcome[:status] == :rejected,
            do: %{next | want_response: MapSet.put(next.want_response, id)},
            else: next

        {:reply, submission_reply(next), continue_response(next)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:control, id, {:input_muted, flag}}, _from, state) when is_boolean(flag) do
    CommandLog.run(state, id, {:input_muted, flag}, fn state, id, _command ->
      next = %{state | muted: flag, outbound: AudioQueue.clear(state.outbound)}
      emit(next, :control_completed, %{muted: flag, scope: :local_input_gate}, id)
      {:reply, :ok, next}
    end)
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:unsupported, "Unsupported Grok command"), state}

  @impl true
  def handle_info(:grok_startup_timeout, %{status: status} = state)
      when status in [:connecting, :starting],
      do: {:noreply, fail(state, :startup_timeout)}

  def handle_info(:grok_startup_timeout, state), do: {:noreply, state}

  def handle_info(
        {:grok_interruption_timeout, token},
        %{interruption: token, output_blocked: true} = state
      ),
      do: {:noreply, fail(state, :interruption_not_cleared)}

  def handle_info({:grok_interruption_timeout, _token}, state), do: {:noreply, state}

  def handle_info(
        {:grok_response_timeout, token},
        %{response: :requested, request_timer: {token, _timer}} = state
      ),
      do: {:noreply, fail(state, :response_timeout)}

  def handle_info({:grok_response_timeout, _token}, state), do: {:noreply, state}

  def handle_info(_message, %{status: :closed} = state), do: {:noreply, state}

  def handle_info(:grok_audio_tick, state) do
    next = input_tick(state)
    {deadline, delay} = Pacer.next(next.deadline, 20_000)
    Process.send_after(self(), :grok_audio_tick, delay)
    {:noreply, %{next | deadline: deadline}}
  end

  def handle_info(message, %{socket: socket} = state) when not is_nil(socket) do
    case WebSocketConnection.receive(socket, message) do
      {:ok, socket, frames} ->
        {:noreply, Enum.reduce(frames, %{state | socket: socket}, &frame/2)}

      {:error, reason} ->
        {:noreply, fail(state, reason)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: WebSocketConnection.close(state.socket)

  defp submit_context(state, id, {:context, update}) do
    case Calls.context(state.calls, update.delegation_id, update.content) do
      {:ok, command, calls} ->
        command = Map.put(command, :event_id, id)

        next =
          transmit(
            %{
              state
              | calls: calls,
                want_response: MapSet.put(state.want_response, update.delegation_id)
            },
            command
          )

        if next.status == :ready,
          do:
            emit(next, :context_submitted, %{outcome: :unconfirmed, evidence: :socket_write}, id)

        {:reply, submission_reply(next), continue_response(next)}

      error ->
        {:reply, error, state}
    end
  end

  defp submission_reply(%{status: :closed}),
    do:
      {:error,
       Error.new(:closed, "Context transmission outcome is unknown", %{outcome: :unknown})}

  defp submission_reply(_state), do: :ok

  # Keep generated audio in the single ordered pipeline. Explicit continuation
  # waits for the current generation and receive queue to drain; none of these
  # observations asserts that physical playback has completed.
  defp continue_response(
         %{
           status: :ready,
           response: nil,
           caller_speaking: false,
           auto_response_pending: false,
           inbound: %{bytes: 0},
           output_blocked: false
         } = state
       ) do
    ready = Enum.reject(state.want_response, &Calls.group_pending?(state.calls, &1))

    if ready == [] do
      state
    else
      token = make_ref()

      timer =
        Process.send_after(
          self(),
          {:grok_response_timeout, token},
          state.init.limits.startup_timeout_ms
        )

      transmit(
        %{
          state
          | want_response: MapSet.difference(state.want_response, MapSet.new(ready)),
            response: :requested,
            request_timer: {token, timer}
        },
        Protocol.respond()
      )
    end
  end

  defp continue_response(state), do: state

  defp frame(_frame, %{status: :closed} = state), do: state
  defp frame(:open, state), do: transmit(%{state | status: :starting}, state.config.setup)

  defp frame({kind, json}, state) when kind in [:text, :binary] do
    case JSON.decode(json) do
      {:ok, event} when is_map(event) -> event(event, state)
      _invalid -> fail(state, :invalid_json)
    end
  end

  defp frame({:ping, bytes}, state), do: wire(state, {:pong, bytes})
  defp frame({:close, _code, _reason}, state), do: fail(state, :socket_closed)
  defp frame({:error, _error}, state), do: fail(state, :malformed_frame)
  defp frame(_frame, state), do: state

  defp ready(state) do
    next =
      Enum.reduce(
        state.config.history,
        %{state | status: :ready, deadline: now()},
        &transmit(&2, &1)
      )

    if next.status == :ready do
      emit(next, :ready, %{capabilities: Protocol.capabilities(), format: state.init.audio_format})

      send(self(), :grok_audio_tick)
    end

    next
  end

  defp event(%{"type" => "session.updated"} = event, %{status: :starting} = state) do
    if Protocol.configured?(event["session"], state.config.setup.session.reasoning.effort),
      do: ready(state),
      else: fail(state, :configuration_mismatch)
  end

  defp event(%{"type" => "input_audio_buffer.speech_started"}, state),
    do: interrupt(%{state | caller_speaking: true, auto_response_pending: true})

  defp event(%{"type" => "input_audio_buffer.speech_stopped"}, state),
    do: continue_response(%{state | caller_speaking: false})

  defp event(%{"type" => type} = event, state)
       when type in [
              "input_audio_buffer.committed",
              "conversation.item.input_audio_transcription.updated",
              "conversation.item.input_audio_transcription.completed"
            ] do
    case Transcripts.observe(state.transcripts, event) do
      {:ok, caption, transcripts} ->
        if caption, do: emit(state, :transcript_delta, caption)
        %{state | transcripts: transcripts}

      {:error, error} ->
        fail(state, error.code)
    end
  end

  defp event(%{"type" => "response.created", "response" => %{"id" => id}}, state)
       when is_binary(id),
       do: start_response(state, id)

  defp event(%{"type" => type, "response_id" => id} = event, state)
       when type in [
              "response.audio.delta",
              "response.output_audio.delta",
              "response.audio_transcript.delta",
              "response.output_audio_transcript.delta"
            ] do
    if MapSet.member?(state.discarded, id) do
      state
    else
      output(event, state)
    end
  end

  defp event(%{"type" => "response.function_call_arguments.done"} = event, state) do
    if MapSet.member?(state.discarded, event["response_id"]),
      do: state,
      else: delegate(event, state)
  end

  defp event(%{"type" => "response.done", "response" => %{"id" => id, "status" => status}}, state) do
    cond do
      MapSet.member?(state.discarded, id) or state.response != id ->
        state

      status == "failed" ->
        fail(state, :response_failed)

      true ->
        emit(state, :provider_speech, %{state: :idle})
        emit(state, :provider_activity, %{state: :idle})
        continue_response(%{state | response: nil})
    end
  end

  defp event(%{"type" => "error", "error" => error}, state) do
    if is_binary(error["event_id"]),
      do:
        emit(
          state,
          :context_rejected,
          %{error: Error.new(:adapter_failed, "Grok rejected a command")},
          error["event_id"]
        )

    fail(state, :provider_rejected)
  end

  defp event(_event, state), do: state

  defp start_response(state, id) do
    cond do
      MapSet.member?(state.discarded, id) or state.response == id ->
        state

      state.caller_speaking ->
        # A requested reply can start after VAD has already interrupted it.
        # Cancel that late generation without consuming the caller's next turn.
        state |> discard_response(id) |> transmit(Protocol.cancel())

      true ->
        state = clear_request_timer(state)
        emit(state, :provider_activity, %{state: :in_progress})
        %{state | response: id, auto_response_pending: false}
    end
  end

  defp delegate(event, state) do
    case Calls.admit(state.calls, Map.put_new(event, "response_id", state.response)) do
      {:new, args, calls} ->
        emit(state, :delegation_requested, %{
          id: event["call_id"],
          target: :client,
          offset_ms: nil,
          arguments: args
        })

        %{state | calls: calls}

      {:duplicate, _calls} ->
        state

      {:error, error} ->
        fail(state, error.code)
    end
  end

  defp output(%{"type" => type, "delta" => encoded}, state)
       when type in ["response.audio.delta", "response.output_audio.delta"] and is_binary(encoded) do
    with {:ok, audio} <- Base.decode64(encoded),
         {:ok, {queue, sequence}} <-
           OutputBuffer.push(state.inbound, audio, state.init, state.sequence, now()) do
      emit(state, :provider_speech, %{state: :speaking})
      notify(%{state | inbound: queue, sequence: sequence})
    else
      {:error, %Error{} = error} -> fail(state, error.code)
      _invalid -> fail(state, :invalid_audio)
    end
  end

  defp output(%{"delta" => text, "item_id" => id}, state)
       when is_binary(text) and byte_size(text) <= 16_384 and is_binary(id) do
    emit(state, :provider_speech, %{state: :speaking})

    emit(state, :transcript_delta, %{
      speaker: :assistant,
      delta: text,
      segment_id: id,
      start_ms: nil,
      end_ms: nil,
      timing: :unavailable
    })

    state
  end

  defp output(_event, state), do: fail(state, :invalid_output)

  defp interrupt(state) do
    state = state |> discard_response(state.response) |> clear_request_timer()
    state = %{state | response: nil}

    if state.status == :closed do
      state
    else
      token = state.interruption + 1
      emit(state, :output_interrupted, %{token: token})
      emit(state, :provider_speech, %{state: :idle})

      Process.send_after(
        self(),
        {:grok_interruption_timeout, token},
        state.init.limits.cancellation_timeout_ms
      )

      %{
        state
        | interruption: token,
          output_blocked: true,
          inbound: AudioQueue.clear(state.inbound),
          waiter: nil
      }
    end
  end

  defp discard_response(state, id) when is_binary(id) do
    discarded = MapSet.put(state.discarded, id)

    if MapSet.size(discarded) > state.init.limits.max_records,
      do: fail(state, :interruption_capacity),
      else: %{state | discarded: discarded}
  end

  defp discard_response(state, _pending_or_idle), do: state

  defp input_tick(%{status: :ready} = state) do
    size = AudioFormat.bytes_for_ms(state.init.audio_format, 20)
    {data, queue} = AudioQueue.take_bytes(state.outbound, size)
    silence = AudioFormat.silence(state.init.audio_format, 20)

    transmit(
      %{state | outbound: queue},
      Protocol.audio(data <> binary_part(silence, 0, size - byte_size(data)))
    )
  end

  defp input_tick(state), do: state

  defp notify(state), do: OutputBuffer.notify(state)

  defp transmit(%{status: :closed} = state, _command), do: state
  defp transmit(state, command), do: wire(state, {:text, JSON.encode!(command)})

  defp wire(state, frame) do
    case WebSocketConnection.send(state.socket, frame) do
      {:ok, socket} -> %{state | socket: socket}
      {:error, reason} -> fail(state, reason)
    end
  end

  defp fail(%{status: :closed} = state, _reason), do: state

  defp fail(state, reason) do
    if reason in [:output_overflow, :output_stale],
      do:
        emit(state, :audio_discontinuity, %{cause: reason, discarded_bytes: state.inbound.bytes})

    emit(state, :failed, %{
      error: Error.new(:adapter_failed, "Grok provider failed", %{reason: reason})
    })

    close(state, reason)
  end

  defp close(%{status: :closed} = state, _reason), do: state

  defp close(state, reason) do
    state = clear_request_timer(state)
    WebSocketConnection.close(state.socket)
    emit(state, :closed, %{reason: reason, finalized?: false})

    %{
      state
      | status: :closed,
        key: nil,
        socket: nil,
        waiter: nil,
        inbound: AudioQueue.clear(state.inbound),
        outbound: AudioQueue.clear(state.outbound)
    }
  end

  defp clear_request_timer(%{request_timer: nil} = state), do: state

  defp clear_request_timer(state) do
    {_token, timer} = state.request_timer
    Process.cancel_timer(timer)
    %{state | request_timer: nil}
  end

  defp emit(state, type, payload, id \\ nil),
    do: Event.emit(state.init, :provider, type, payload, command_id: id)

  defp now, do: System.monotonic_time(:microsecond)
end
