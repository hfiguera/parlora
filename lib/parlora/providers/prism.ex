defmodule Parlora.Providers.Prism do
  @moduledoc """
  Rime Prism with client delegation and full-duplex mono PCM16LE/24 kHz.

  Pass `:api_key`, optional `:voice` (defaults to `"astra"`), and session
  instructions. The adapter converts caller audio to 16 kHz and keeps the
  uplink running through silence and mute. Prism's conversation model is `"prism"`.

  A tool result is acknowledged when Prism records it. The adapter then
  requests one continuation after the parent reply ends and all its results
  are acknowledged. New caller speech supersedes the old continuation.
  Delegations for caller audio wait until its final transcripts reach Parlora.
  Pending backend results survive interruptions before their audio reaches playback.
  A proactive result reply waits for Prism to be idle, committed caller transcripts
  to finish, and the session to confirm the result is current.
  Playback clears on confirmed speech, including after generation ends.
  Channels that can return an interrupted item's played position enable a
  truncation report. Other channels use Prism's server-side playback estimate.
  """
  use GenServer
  use Parlora.ProviderClient, protocol: Parlora.Providers.Prism.Protocol, client_tools: true

  alias Parlora.{Adapter, AudioConverter, AudioFormat, AudioFrame, AudioQueue, CommandLog}
  alias Parlora.{Error, Event, ID, Pacer}
  alias Parlora.Provider.{OutputBuffer, WebSocketConnection}
  alias Parlora.Providers.Prism.{Calls, Protocol}

  @endpoint {:https, "prism.api.rime.ai", 443}
  @chunk_ms 20
  @request_timeout_ms 10_000

  @impl true
  def audio_limits(format), do: OutputBuffer.burst_limits(format, 30_000)

  @impl true
  def resume_output(pid, token, position),
    do: Adapter.call(pid, {:resume_output, token, position})

  @impl true
  def init({init, options, config}) do
    {:ok,
     %{
       init: init,
       key: Keyword.fetch!(options, :api_key),
       config: config,
       socket: nil,
       status: :connecting,
       setup_id: nil,
       commands: %CommandLog{limit: init.limits.max_records},
       calls: Calls.new(init.limits.max_records),
       caller_transcripts: %{},
       pending_transcripts: %{},
       response_inputs: [],
       deferred_calls: [],
       late_results: :queue.new(),
       late_check: nil,
       requests: %{},
       inbound: OutputBuffer.new(init.limits),
       outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
       input: AudioConverter.new(24_000, 16_000, 1, 1),
       sequence: 0,
       waiter: nil,
       muted: false,
       deadline: nil,
       typed_ready?: false,
       drain: nil,
       response: nil,
       discarded: nil,
       interrupted_reply: nil,
       had_audio?: false,
       speaking?: false,
       output_blocked: false,
       interruption: 0
     }, {:continue, :connect}}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: %{status: status.state.status}, message: :redacted, log: []})

  @impl true
  def handle_continue(:connect, state) do
    Process.send_after(self(), :startup_timeout, state.init.limits.startup_timeout_ms)
    headers = [{"authorization", "Bearer " <> state.key}]

    case WebSocketConnection.connect(@endpoint, "/v1/realtime", headers) do
      {:ok, socket} -> {:noreply, %{state | socket: socket, key: nil}}
      {:error, reason} -> {:noreply, fail(state, reason)}
    end
  end

  @impl true
  def handle_call({:close, id, reason}, _from, state),
    do: {:reply, :ok, close_state(state, reason, id)}

  def handle_call(_command, _from, %{status: :closed} = state),
    do: {:reply, Error.tuple(:closed, "Prism provider is closed"), state}

  def handle_call(_command, _from, %{status: status} = state) when status != :ready,
    do: {:reply, Error.tuple(:not_ready, "Prism session is not ready"), state}

  def handle_call(:capabilities, _from, state),
    do: {:reply, {:ok, Protocol.capabilities()}, state}

  def handle_call(:output_buffer_status, _from, state),
    do:
      {:reply,
       {:ok, %{queued_bytes: state.inbound.bytes, capacity_bytes: state.inbound.capacity}}, state}

  def handle_call({:arm_output_ready, reader, reference}, _from, state)
      when is_pid(reader) and is_reference(reference),
      do: {:reply, :ok, OutputBuffer.notify(%{state | waiter: {reader, reference}})}

  def handle_call({:read, _budget}, _from, %{output_blocked: true} = state),
    do: {:reply, {:ok, []}, state}

  def handle_call({:read, budget}, _from, state) do
    case OutputBuffer.reply_read(state, budget, &Function.identity/1, &fail/2) do
      {:reply, {:ok, [_ | _] = frames}, next} ->
        calls = Calls.read_audio(next.calls, List.last(frames).sequence)
        {:reply, {:ok, frames}, %{next | calls: calls}}

      reply ->
        reply
    end
  end

  def handle_call({:write, frame}, _from, state) do
    with :ok <- AudioFrame.validate(frame, state.init.audio_format, state.init.limits),
         {:ok, queue} <- queue_input(state, frame) do
      {:reply, :ok, %{state | outbound: queue}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resume_output, token}, from, state),
    do: handle_call({:resume_output, token, nil}, from, state)

  def handle_call({:resume_output, token, position}, _from, state) do
    if state.output_blocked and token == state.interruption do
      next =
        state
        |> report_position(position)
        |> recover_unplayed_reply(position)
        |> Map.put(:output_blocked, false)
        |> maybe_continue()

      {:reply, submission_reply(next), OutputBuffer.notify(next)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:append, update}, _from, state) do
    command = {:context, update}

    with :ok <- Protocol.validate(update, state.init.generation),
         {:new, log} <- CommandLog.admit(state.commands, update.id, command) do
      case submit_context(state, update) do
        {:ok, next} -> CommandLog.complete({:reply, submission_reply(next), next}, log, update.id)
        error -> {:reply, error, state}
      end
    else
      {:duplicate, log} -> {:reply, CommandLog.reply(log, update.id), state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resolve_delegation, id, %{status: _} = outcome}, _from, state) do
    case Calls.status(state.calls, id) do
      :pending ->
        next = resolve_result(state, id, outcome)
        {:reply, submission_reply(next), next}

      status when status in [:submitted, :acknowledged] ->
        {:reply, :ok, state}

      _other ->
        {:reply, Error.tuple(:invalid_argument, "Unknown or rejected Prism delegation"), state}
    end
  end

  def handle_call({:control, id, {:input_muted, flag} = command}, _from, state)
      when is_boolean(flag) do
    CommandLog.run(state, id, command, fn current, command_id, _command ->
      next = %{
        current
        | muted: flag,
          outbound: AudioQueue.clear(current.outbound),
          input: AudioConverter.reset(current.input)
      }

      emit(next, :control_completed, %{muted: flag, scope: :local_input_gate}, command_id)
      {:reply, :ok, next}
    end)
  end

  def handle_call({:control, id, {:output_discarded, response} = command}, _from, state) do
    CommandLog.run(state, id, command, fn
      %{drain: {^response, token}} = current, _id, _command ->
        next = send_command(%{current | drain: nil}, Protocol.playback_drained(token))
        {:reply, submission_reply(next), next}

      current, _id, _command ->
        {:reply, Error.tuple(:not_ready, "No matching Prism playback receipt"), current}
    end)
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:unsupported, "Unsupported Prism command"), state}

  @impl true
  def handle_info(:startup_timeout, %{status: status} = state)
      when status in [:connecting, :starting, :configured],
      do: {:noreply, fail(state, :startup_timeout)}

  def handle_info(:startup_timeout, state), do: {:noreply, state}

  def handle_info(
        {:interruption_timeout, token},
        %{interruption: token, output_blocked: true} = state
      ),
      do: {:noreply, fail(state, :interruption_not_cleared)}

  def handle_info({:interruption_timeout, _token}, state), do: {:noreply, state}

  def handle_info({:request_timeout, wire_id}, state),
    do: {:noreply, request_failed(state, wire_id, :timeout)}

  def handle_info({:parlora_delivery_current, ref, current?}, %{late_check: {ref, item}} = state) do
    state = %{state | late_check: nil}
    {:noreply, finish_late_check(state, item, current?)}
  end

  def handle_info(_message, %{status: :closed} = state), do: {:noreply, state}

  def handle_info(:audio_tick, state) do
    size = AudioFormat.bytes_for_ms(state.init.audio_format, @chunk_ms)
    {pcm, queue} = AudioQueue.take_bytes(state.outbound, size)

    {audio, input} =
      AudioConverter.convert(state.input, pcm <> :binary.copy(<<0>>, size - byte_size(pcm)))

    {deadline, delay} = Pacer.next(state.deadline, @chunk_ms * 1_000)
    next = %{state | outbound: queue, input: input, deadline: deadline}
    next = if audio == <<>>, do: next, else: send_command(next, Protocol.audio(audio))
    if next.status == :ready, do: Process.send_after(self(), :audio_tick, delay)
    {:noreply, next}
  end

  def handle_info(message, %{socket: socket} = state) when socket != nil,
    do: {:noreply, WebSocketConnection.consume(state, message, &frame/2, &fail/2)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: release(state)

  defp queue_input(%{muted: true, outbound: queue}, _frame), do: {:ok, queue}
  defp queue_input(state, frame), do: AudioQueue.push(state.outbound, frame)

  defp frame(_frame, %{status: :closed} = state), do: state
  defp frame(:open, state), do: %{state | status: :starting}

  defp frame({:text, bytes}, state),
    do: WebSocketConnection.json(state, bytes, &event/2, &fail/2)

  defp frame({:ping, bytes}, state),
    do: WebSocketConnection.write(state, {:pong, bytes}, &fail/2)

  defp frame({:close, _code, _reason}, state), do: fail(state, :socket_closed)
  defp frame({:pong, _bytes}, state), do: state
  defp frame(_frame, state), do: fail(state, :invalid_frame)

  defp event(%{"type" => "session.created"}, %{status: :starting, setup_id: nil} = state) do
    id = ID.new()
    send_command(%{state | setup_id: id}, Map.put(Protocol.setup(state.config), :event_id, id))
  end

  defp event(
         %{"type" => "session.updated", "prism_request_event_id" => id, "session" => session},
         %{status: :starting, setup_id: id} = state
       )
       when is_binary(id) do
    if Protocol.configured?(session, state.config) do
      %{state | status: :configured}
    else
      fail(state, :configuration_mismatch)
    end
  end

  defp event(%{"type" => "prism.typed_input.ready"}, %{status: :configured} = state) do
    emit(state, :ready, %{capabilities: Protocol.capabilities(), format: state.init.audio_format})
    emit(state, :provider_speech, %{state: :idle, typed_ready: true})
    send(self(), :audio_tick)
    %{state | status: :ready, deadline: now(), typed_ready?: true}
  end

  defp event(%{"type" => "error"}, %{status: status} = state)
       when status in [:starting, :configured],
       do: fail(state, :setup_rejected)

  defp event(_event, %{status: status} = state) when status in [:starting, :configured], do: state

  defp event(%{"type" => "prism.typed_input.ready"}, state) do
    emit(state, :provider_speech, %{state: :idle, typed_ready: true})
    %{state | typed_ready?: true, speaking?: false, drain: nil} |> maybe_report_late()
  end

  defp event(%{"type" => "input_audio_buffer.speech_started"} = event, state) do
    state = defer_late_check(state)

    state =
      %{state | typed_ready?: false, drain: nil}
      |> preserve_interrupted_results()
      |> supersede()

    state =
      if state.status == :ready and (state.response || state.had_audio?),
        do: interrupt(state),
        else: state

    if valid_item_id?(event["item_id"]) do
      emit(state, :extension, %{
        kind: :caller_speech,
        state: :started,
        segment_id: event["item_id"],
        evidence: :provider_vad
      })
    end

    state
  end

  defp event(%{"type" => "input_audio_buffer.speech_stopped", "item_id" => id}, state)
       when is_binary(id) do
    emit(state, :extension, %{kind: :caller_speech, state: :stopped, segment_id: id})
    state
  end

  defp event(%{"type" => "input_audio_buffer.committed", "item_id" => item}, state) do
    cond do
      not valid_item_id?(item) ->
        fail(state, :invalid_input_item)

      Map.has_key?(state.caller_transcripts, item) or
          Map.has_key?(state.pending_transcripts, item) ->
        state

      map_size(state.pending_transcripts) >= state.init.limits.max_records ->
        fail(state, :transcript_record_capacity)

      true ->
        state = defer_late_check(state)

        %{
          state
          | typed_ready?: false,
            pending_transcripts: Map.put(state.pending_transcripts, item, true)
        }
    end
  end

  defp event(
         %{"type" => "response.created", "response" => %{"id" => id} = response} = event,
         state
       )
       when is_binary(id) do
    inputs = Map.get(response, "prism_input_item_ids", [])

    if valid_input_items?(inputs, state.init.limits.max_records) do
      # A result reply that only repeats its tool call gets one chance to speak.
      # A reply to that retry cannot open another retry for the same result.
      {recover_association?, reply_results} =
        case state.requests[event["prism_request_event_id"]] do
          {{:reply, kind, results}, _timer} -> {kind in [:continue, :late_reply], results}
          _other -> {false, []}
        end

      state = state |> acknowledge(event) |> supersede()
      emit(state, :provider_activity, %{state: :in_progress, response_id: id})

      %{
        state
        | response: id,
          drain: nil,
          response_inputs: inputs,
          typed_ready?: false,
          calls: Calls.begin(state.calls, id, state.sequence, recover_association?, reply_results)
      }
    else
      fail(state, :invalid_response_inputs)
    end
  end

  defp event(
         %{"type" => "response.done", "response" => %{"id" => id, "status" => status} = reply},
         %{response: id} = state
       ) do
    reason = get_in(reply, ["status_details", "reason"])

    emit(state, :provider_activity, %{
      state: :idle,
      response_id: id,
      status: status,
      reason: reason
    })

    token = get_in(reply, ["metadata", "prism_drain_token"])
    drain = if valid_item_id?(token), do: {id, token}

    state = settle_ended_reply(state, status, reason)

    %{state | response: nil, drain: drain, calls: Calls.finish(state.calls, id, status)}
    |> discard_failed_reply(status)
    |> maybe_continue()
  end

  defp event(
         %{"type" => "response.audio.delta", "response_id" => id},
         %{discarded: id} = state
       ),
       do: state

  defp event(
         %{
           "type" => "response.audio.delta",
           "response_id" => id,
           "item_id" => item,
           "delta" => audio
         },
         %{response: id} = state
       )
       when is_binary(item) and byte_size(item) in 1..512 and is_binary(audio) do
    with {:ok, pcm} when pcm != <<>> <- Base.decode64(audio),
         {:ok, {queue, sequence}} <-
           OutputBuffer.push(state.inbound, pcm, state.init, state.sequence, now(), item) do
      unless state.speaking?, do: emit(state, :provider_speech, %{state: :speaking})

      OutputBuffer.notify(%{
        state
        | inbound: queue,
          calls: Calls.generated_audio(state.calls, item),
          sequence: sequence,
          had_audio?: true,
          speaking?: true
      })
    else
      {:ok, <<>>} -> state
      {:error, %Error{} = error} -> fail(state, error.code)
      _invalid -> fail(state, :invalid_audio)
    end
  end

  defp event(%{"type" => "response.audio.delta"}, state), do: fail(state, :invalid_audio)

  defp event(
         %{
           "type" => "response.text.done",
           "response_id" => id,
           "item_id" => item,
           "text" => text
         },
         %{response: id} = state
       )
       when id != state.discarded,
       do: transcript(state, :assistant, item, text)

  defp event(
         %{
           "type" => "conversation.item.input_audio_transcription.completed",
           "item_id" => item,
           "transcript" => text
         },
         state
       ),
       do: finalize_input(state, item, text)

  defp event(
         %{"type" => "conversation.item.input_audio_transcription.failed", "item_id" => item},
         state
       ),
       do: finalize_input(state, item, nil)

  defp event(%{"type" => "response.function_call_arguments.done", "call_id" => id} = event, state) do
    case Calls.admit(state.calls, event) do
      {:new, args, calls} ->
        %{state | calls: calls, deferred_calls: [{id, args} | state.deferred_calls]}
        |> publish_delegations()

      {:stale, ^id, calls} ->
        submit_result(%{state | calls: calls}, id, %{status: :superseded}, nil, false)

      {:duplicate, _log} ->
        state

      {:error, error} ->
        fail(state, error.code)
    end
  end

  defp event(%{"type" => type} = event, state)
       when type in ["conversation.item.created", "conversation.item.truncated"],
       do: acknowledge(state, event)

  defp event(%{"type" => "error", "error" => %{"scope" => "session"}}, state),
    do: fail(state, :provider_rejected)

  defp event(
         %{
           "type" => "error",
           "error" => %{"code" => "tool_result_timeout", "owner" => %{"response_id" => id}}
         },
         state
       ),
       do: expire_round(state, id)

  defp event(%{"type" => "error", "error" => %{"event_id" => id, "code" => code}}, state),
    do: request_failed(state, id, code)

  defp event(_event, state), do: state

  defp valid_input_items?(items, limit) when is_list(items),
    do: Enum.count_until(items, limit + 1) <= limit and Enum.all?(items, &valid_item_id?/1)

  defp valid_input_items?(_items, _limit), do: false

  defp valid_item_id?(id), do: is_binary(id) and byte_size(id) in 1..512

  defp finalize_input(state, item, text) do
    cond do
      not valid_item_id?(item) ->
        fail(state, :invalid_input_item)

      Map.has_key?(state.caller_transcripts, item) ->
        state

      map_size(state.caller_transcripts) >= state.init.limits.max_records ->
        fail(state, :transcript_record_capacity)

      valid_caller_text?(text) ->
        state = transcript(state, :user, item, text)
        finish_transcript(state, item, :ready)

      true ->
        emit(state, :extension, %{
          kind: :transcript_discarded,
          cause: :transcription_unavailable,
          speaker: :user,
          segment_id: item
        })

        finish_transcript(state, item, :unavailable)
    end
  end

  defp finish_transcript(state, item, status) do
    %{
      state
      | caller_transcripts: Map.put(state.caller_transcripts, item, status),
        pending_transcripts: Map.delete(state.pending_transcripts, item)
    }
    |> publish_delegations()
    |> maybe_report_late()
  end

  defp valid_caller_text?(text) when is_binary(text) and byte_size(text) in 1..32_768,
    do: String.trim(text) != ""

  defp valid_caller_text?(_text), do: false

  defp publish_delegations(%{deferred_calls: []} = state), do: state

  defp publish_delegations(state) do
    transcripts = Enum.map(state.response_inputs, &state.caller_transcripts[&1])

    cond do
      :unavailable in transcripts ->
        reject_deferred(
          state,
          %{status: :missing_transcript, result: "Ask the caller to repeat."},
          true
        )

      nil in transcripts ->
        state

      true ->
        Enum.each(Enum.reverse(state.deferred_calls), fn {id, args} ->
          emit(state, :delegation_requested, %{
            id: id,
            target: :client,
            offset_ms: nil,
            arguments: args
          })
        end)

        %{state | deferred_calls: []}
    end
  end

  defp discard_failed_reply(state, "completed"), do: state
  defp discard_failed_reply(state, _status), do: supersede(state)

  defp settle_ended_reply(
         %{response: id, discarded: id} = state,
         "cancelled",
         "turn_detected"
       ),
       do: state

  defp settle_ended_reply(state, "cancelled", "turn_detected") do
    %{state | typed_ready?: false}
    |> preserve_interrupted_results()
    |> interrupt()
  end

  defp settle_ended_reply(state, "failed", "response_timeout") do
    {results, calls} = Calls.retry_timed_out(state.calls)
    requeue_results(%{state | calls: calls}, results)
  end

  defp settle_ended_reply(state, _status, _reason), do: state

  defp expire_round(%{calls: %{round: %{id: id}}} = state, id), do: supersede(state)
  defp expire_round(state, _id), do: state

  defp supersede(state) do
    %{state | calls: Calls.supersede(state.calls), response_inputs: []}
    |> reject_deferred(%{status: :superseded}, false)
  end

  defp reject_deferred(state, result, speak?) do
    Enum.reduce(Enum.reverse(state.deferred_calls), %{state | deferred_calls: []}, fn
      {id, _args}, current -> submit_result(current, id, result, nil, speak?)
    end)
  end

  defp transcript(state, speaker, item, text)
       when is_binary(text) and byte_size(text) in 1..32_768 and is_binary(item) do
    emit(state, :transcript_delta, %{
      speaker: speaker,
      segment_id: item,
      delta: text,
      start_ms: nil,
      end_ms: nil,
      timing: :unavailable
    })

    state
  end

  defp transcript(state, _speaker, _item, _text), do: state

  defp interrupt(state) do
    token = state.interruption + 1
    emit(state, :output_interrupted, %{token: token, response_id: state.response})
    emit(state, :provider_speech, %{state: :idle})

    Process.send_after(
      self(),
      {:interruption_timeout, token},
      state.init.limits.startup_timeout_ms
    )

    %{
      state
      | interruption: token,
        discarded: state.response || state.discarded,
        had_audio?: false,
        speaking?: false,
        inbound: AudioQueue.clear(state.inbound),
        output_blocked: true
    }
  end

  defp report_position(state, %{stream_id: item, played_ms: ms})
       when is_binary(item) and byte_size(item) in 1..512 and is_integer(ms) and
              ms in 0..4_294_967_295,
       do: request(state, Protocol.truncate(item, ms), {:truncate, item, ms})

  defp report_position(state, _position), do: state

  defp submit_context(state, %{delegation_id: nil} = update), do: nudge(state, update)

  defp submit_context(state, update) do
    case Calls.status(state.calls, update.delegation_id) do
      :pending ->
        {:ok,
         submit_result(
           state,
           update.delegation_id,
           %{result: update.content},
           update.id,
           true,
           backend_result(update)
         )}

      :acknowledged ->
        nudge(state, update)

      :submitted ->
        Error.tuple(:backpressure, "Prism is still acknowledging the previous result")

      _other ->
        Error.tuple(:invalid_argument, "Unknown or rejected Prism delegation")
    end
  end

  defp backend_result(%{origin: :backend_result} = update), do: update
  defp backend_result(_update), do: nil

  defp nudge(%{typed_ready?: true, output_blocked: false} = state, update) do
    {:ok,
     request(%{state | typed_ready?: false}, Protocol.nudge(update.content), {:nudge, update.id})}
  end

  defp nudge(_state, _update),
    do: Error.tuple(:backpressure, "Prism must be idle before it can accept a proactive reply")

  defp resolve_result(
         state,
         id,
         %{
           status: :associated,
           task_status: :completed,
           result_delivery: :accepted,
           result: result
         } = outcome
       )
       when is_binary(result) and result != "" do
    if Calls.recover_association?(state.calls, id) do
      outcome =
        Map.put(
          outcome,
          :instruction,
          "Speak the verified result to the caller now. " <>
            "If it asks a question, ask it and wait for the caller before calling a tool again."
        )

      submit_result(state, id, outcome, nil, :association)
    else
      submit_result(state, id, outcome, nil, false)
    end
  end

  defp resolve_result(state, id, %{status: status} = outcome),
    do: submit_result(state, id, outcome, nil, status in [:rejected, :failed])

  defp submit_result(state, id, result, command_id, speech, delivery \\ nil) do
    state = %{state | calls: Calls.submit(state.calls, id, speech)}
    request(state, Protocol.result(id, result), {:result, id, command_id, delivery})
  end

  defp maybe_continue(%{status: :ready, response: nil, output_blocked: false} = state) do
    case Calls.continuation(state.calls) do
      {parent, kind, results, calls} ->
        request(
          %{state | calls: calls, typed_ready?: false},
          Protocol.continue(parent),
          {:reply, kind, results}
        )

      nil ->
        maybe_report_late(state)
    end
  end

  defp maybe_continue(state), do: state

  defp acknowledge_result(state, call, update) do
    if update && not Calls.in_round?(state.calls, call) do
      %{
        state
        | calls: Calls.acknowledge(state.calls, call),
          late_results: :queue.in({call, update}, state.late_results)
      }
    else
      %{state | calls: Calls.acknowledge(state.calls, call, update)}
    end
  end

  # A new turn invalidates the pending freshness check. Check again when idle.
  defp defer_late_check(%{late_check: {_ref, item}} = state),
    do: %{state | late_results: :queue.in_r(item, state.late_results), late_check: nil}

  defp defer_late_check(state), do: state

  defp requeue_results(state, []), do: state

  defp requeue_results(state, results) do
    %{state | late_results: :queue.join(:queue.from_list(results), state.late_results)}
  end

  defp preserve_interrupted_results(state) do
    state = requeue_results(state, Calls.unspoken_results(state.calls))
    candidate = Calls.interrupted_reply(state.calls) || state.interrupted_reply
    %{state | interrupted_reply: candidate}
  end

  defp recover_unplayed_reply(%{interrupted_reply: {first, stream, results}} = state, position) do
    state = %{state | interrupted_reply: nil}

    case position do
      %{last_handed_off_sequence: last} when is_nil(last) or last < first ->
        requeue_results(state, results)

      %{last_forwarded_sequence: last} when is_nil(last) or last < first ->
        requeue_results(state, results)

      %{stream_id: ^stream, played_ms: 0} ->
        requeue_results(state, results)

      _other ->
        state
    end
  end

  defp recover_unplayed_reply(state, _position), do: state

  defp maybe_report_late(
         %{
           status: :ready,
           typed_ready?: true,
           output_blocked: false,
           response: nil,
           late_check: nil,
           pending_transcripts: pending
         } = state
       )
       when map_size(pending) == 0 do
    case :queue.out(state.late_results) do
      {{:value, {_call, update} = item}, rest} ->
        ref = make_ref()
        send(state.init.event_sink, {:parlora_check_delivery, self(), ref, update})
        %{state | late_results: rest, late_check: {ref, item}}

      {:empty, _rest} ->
        state
    end
  end

  defp maybe_report_late(state), do: state

  defp finish_late_check(
         %{status: :ready, typed_ready?: true, output_blocked: false, response: nil} = state,
         {call, update},
         true
       ),
       do:
         request(
           %{state | typed_ready?: false},
           Protocol.report_result(call),
           {:reply, :late_reply, [{call, update}]}
         )

  defp finish_late_check(state, item, true),
    do: %{state | late_results: :queue.in_r(item, state.late_results)}

  defp finish_late_check(state, _item, false), do: maybe_report_late(state)

  defp request(%{status: :closed} = state, _command, _request), do: state

  defp request(state, command, request) do
    id = ID.new()
    timer = Process.send_after(self(), {:request_timeout, id}, @request_timeout_ms)
    state = put_in(state.requests[id], {request, timer})
    send_command(state, Map.put(command, :event_id, id))
  end

  defp acknowledge(state, %{"prism_request_event_id" => id} = event) do
    case {state.requests[id], event} do
      {{{:result, call, command, delivery}, _timer},
       %{"item" => %{"type" => "function_call_output", "call_id" => call}}} ->
        context_ack(state, command, :item_created)
        state |> forget(id) |> acknowledge_result(call, delivery) |> maybe_continue()

      {{{:nudge, command}, _timer},
       %{"type" => "response.created", "response" => %{"id" => reply}}} ->
        context_ack(state, command, :response_created, %{response_id: reply})
        forget(state, id)

      {{{:reply, _kind, _results}, _timer}, %{"type" => "response.created"}} ->
        forget(state, id)

      {{{:truncate, item, ms}, _timer},
       %{"type" => "conversation.item.truncated", "item_id" => item, "audio_end_ms" => ms}} ->
        emit(state, :output_truncated, %{
          stream_id: item,
          played_ms: ms,
          kept_text: event["prism_kept_text"]
        })

        forget(state, id)

      _other ->
        state
    end
  end

  defp acknowledge(state, _event), do: state

  defp request_failed(state, id, reason) do
    case state.requests[id] do
      {{:result, call, command, _delivery}, _timer} ->
        context_error(state, command, reason)
        state = forget(state, id)
        %{state | calls: Calls.reject(state.calls, call)}

      {{:nudge, command}, _timer} ->
        context_error(state, command, reason)
        forget(state, id)

      {{:reply, kind, results}, _timer} ->
        state = report_request_failure(state, id, kind, reason)

        if retryable_reply?(kind, reason),
          do: state |> requeue_results(results) |> maybe_report_late(),
          else: state

      {{:truncate, _, _}, _timer} ->
        report_request_failure(state, id, :truncate, reason)

      nil ->
        state
    end
  end

  defp retryable_reply?(:continue, reason),
    do: reason in ["response_superseded", "tool_continuation_unavailable"]

  defp retryable_reply?(:association_retry, "response_superseded"), do: true

  defp retryable_reply?(:late_reply, reason),
    do: reason in ["nudge_superseded", "instructions_busy"]

  defp retryable_reply?(_kind, _reason), do: false

  defp report_request_failure(state, id, kind, reason) do
    :telemetry.execute([:parlora, :provider, :prism, :request_failed], %{count: 1}, %{
      session_id: state.init.session_id,
      request: kind,
      reason: reason
    })

    forget(state, id)
  end

  defp forget(state, id) do
    {{_request, timer}, requests} = Map.pop!(state.requests, id)
    Process.cancel_timer(timer)
    %{state | requests: requests}
  end

  defp context_ack(state, id, acceptance, details \\ %{})

  defp context_ack(_state, nil, _acceptance, _details), do: :ok

  defp context_ack(state, id, acceptance, details),
    do: emit(state, :context_acknowledged, Map.put(details, :acceptance, acceptance), id)

  defp context_error(_state, nil, _reason), do: :ok

  defp context_error(state, id, reason) do
    payload =
      case reason do
        :timeout ->
          %{outcome: :unknown, error: Error.new(:timeout, "Prism acknowledgment timed out")}

        code when code in ["instructions_busy", "nudge_superseded"] ->
          %{
            error:
              Error.new(:backpressure, "Prism could not start the reply", %{provider_code: code})
          }

        code ->
          %{error: Error.new(:adapter_failed, "Prism refused context", %{provider_code: code})}
      end

    emit(state, :context_rejected, payload, id)
  end

  defp send_command(state, command), do: WebSocketConnection.command(state, command, &fail/2)

  defp submission_reply(%{status: :closed}),
    do: Error.tuple(:closed, "Prism transmission outcome is unknown", %{outcome: :unknown})

  defp submission_reply(_state), do: :ok

  defp fail(%{status: :closed} = state, _reason), do: state

  defp fail(state, reason) do
    code = if reason in [:output_stale, :output_overflow], do: reason, else: :adapter_failed
    emit(state, :failed, %{error: Error.new(code, "Prism provider failed", %{reason: reason})})
    close_state(state, reason, nil)
  end

  defp close_state(%{status: :closed} = state, _reason, _id), do: state

  defp close_state(state, reason, id) do
    Enum.each(state.requests, fn {_id, {_request, timer}} -> Process.cancel_timer(timer) end)
    release(state)
    emit(state, :closed, %{reason: reason, finalized?: false}, id)

    %{
      state
      | status: :closed,
        key: nil,
        socket: nil,
        input: nil,
        waiter: nil,
        requests: %{},
        inbound: AudioQueue.clear(state.inbound),
        outbound: AudioQueue.clear(state.outbound)
    }
  end

  defp release(state) do
    if state.input, do: AudioConverter.close(state.input)
    WebSocketConnection.close(state.socket)
  end

  defp emit(state, type, payload, id \\ nil),
    do: Event.emit(state.init, :provider, type, payload, command_id: id)

  defp now, do: System.monotonic_time(:microsecond)
end
