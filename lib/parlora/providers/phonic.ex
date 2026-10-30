defmodule Parlora.Providers.Phonic do
  @moduledoc """
  Phonic-1 speech-to-speech with application-owned async backend work.

  Caller transcripts are word fragments with unavailable timestamps. Speech
  boundaries delimit assistant captions and interruption epochs. Speakable
  updates schedule a reply after the current generation and receive queue drain.
  Tool outputs may receive provider-processing acknowledgments; other context
  writes remain unconfirmed. Neither observation establishes physical playback.

  Input mute is a local gate that sends codec silence. Network loss closes the
  adapter explicitly; automatic reconnect, initial history and usage reporting
  are not implemented. Phonic's default retention policy applies unless
  `zero_data_retention: true` is requested and enabled for the organization.
  """
  use GenServer
  use Parlora.ProviderClient, protocol: Parlora.Providers.Phonic.Protocol, client_tools: true

  alias Parlora.{
    AudioFormat,
    AudioFrame,
    AudioQueue,
    CommandLog,
    Error,
    Event,
    ID,
    Pacer
  }

  alias Parlora.Provider.{OutputBuffer, WebSocketConnection}
  alias Parlora.Providers.Phonic.{Audio, Calls, Protocol}

  @impl true
  def audio_limits(format \\ %AudioFormat{}), do: OutputBuffer.burst_limits(format, 20_000)

  @impl true
  def init({init, options, config}) do
    state = %{
      init: init,
      key: Keyword.fetch!(options, :api_key),
      config: config,
      socket: nil,
      status: :connecting,
      conversation_id: nil,
      commands: %CommandLog{limit: init.limits.max_records},
      calls: Calls.new(init.limits.max_records),
      associated_results: MapSet.new(),
      tool_timers: %{},
      acknowledgments: %{},
      tool_timeout_ms: config.tools |> hd() |> Map.fetch!(:tool_call_output_timeout_ms),
      acknowledgment_timeout_ms: Keyword.get(options, :acknowledgment_timeout_ms, 5_000),
      response_timeout_ms: Keyword.get(options, :response_timeout_ms, 15_000),
      response_watch: nil,
      inbound: OutputBuffer.new(init.limits),
      outbound: %AudioQueue{capacity: init.limits.audio_queue_bytes},
      audio: Audio.new(init.audio_format),
      sequence: 0,
      waiter: nil,
      muted: false,
      interruption: 0,
      interrupted?: false,
      output_blocked: false,
      accepting_output?: false,
      speech: :idle,
      caption_id: nil,
      caller_speaking: false,
      auto_response_pending: false,
      continuation?: false,
      deadline: now()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: %{status: status.state.status}, message: :redacted})

  @impl true
  def handle_continue(:connect, state) do
    Process.send_after(self(), :phonic_startup_timeout, state.init.limits.startup_timeout_ms)

    case WebSocketConnection.connect({:https, "api.phonic.ai", 443}, Protocol.path(), [
           {"authorization", "Bearer " <> state.key}
         ]) do
      {:ok, socket} -> {:noreply, %{state | socket: socket}}
      {:error, reason} -> {:noreply, fail(state, reason)}
    end
  end

  @impl true
  def handle_call({:close, _id, reason}, _from, state), do: {:reply, :ok, close(state, reason)}

  def handle_call(_command, _from, %{status: :closed} = state),
    do: {:reply, Error.tuple(:closed, "Phonic provider is closed"), state}

  def handle_call(:capabilities, _from, %{status: :ready} = state),
    do: {:reply, {:ok, Protocol.capabilities()}, state}

  def handle_call(:output_buffer_status, _from, state),
    do:
      {:reply,
       {:ok, %{queued_bytes: state.inbound.bytes, capacity_bytes: state.inbound.capacity}}, state}

  def handle_call({:arm_output_ready, reader, reference}, _from, state)
      when is_pid(reader) and is_reference(reference),
      do: {:reply, :ok, OutputBuffer.notify(%{state | waiter: {reader, reference}})}

  def handle_call({:resume_output, token}, _from, state),
    do: OutputBuffer.resume(state, token, &continue_response/1)

  def handle_call({:read, _budget}, _from, %{output_blocked: true} = state),
    do: {:reply, {:ok, []}, state}

  def handle_call({:read, budget}, _from, state),
    do: OutputBuffer.reply_read(state, budget, &continue_response/1, &fail/2)

  def handle_call({:write, frame}, _from, %{status: :ready} = state) do
    case AudioFrame.validate(frame, state.init.audio_format, state.init.limits) do
      :ok -> accept_input(state, frame)
      error -> {:reply, error, state}
    end
  end

  def handle_call(_command, _from, %{status: status} = state) when status != :ready,
    do: {:reply, Error.tuple(:not_ready, "Phonic conversation is not ready"), state}

  def handle_call({:append, update}, _from, state),
    do: Parlora.ProviderClient.context(state, update, &Protocol.validate/2, &submit_context/3)

  def handle_call({:resolve_delegation, id, outcome}, _from, state) when is_map(outcome) do
    case Calls.complete(state.calls, id, outcome) do
      {:ok, command, calls} ->
        next = state |> cancel_timer(:tool_timers, id) |> Map.put(:calls, calls)
        next = transmit(next, command)
        next = association_continuation(next, outcome)
        {:reply, submission_reply(next), continue_response(next)}

      {terminal, _calls} when terminal in [:duplicate, :expired] ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:control, id, {:input_muted, flag}}, _from, state) when is_boolean(flag) do
    CommandLog.run(state, id, {:input_muted, flag}, fn state, id, _command ->
      next = %{
        state
        | muted: flag,
          outbound: AudioQueue.clear(state.outbound),
          audio: Audio.reset(state.audio, :input)
      }

      emit(next, :control_completed, %{muted: flag, scope: :local_input_gate}, id)
      {:reply, :ok, next}
    end)
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:unsupported, "Unsupported Phonic command"), state}

  @impl true
  def handle_info(:phonic_startup_timeout, %{status: status} = state)
      when status in [:connecting, :starting],
      do: {:noreply, fail(state, :startup_timeout)}

  def handle_info(:phonic_startup_timeout, state), do: {:noreply, state}

  def handle_info(_message, %{status: :closed} = state), do: {:noreply, state}

  def handle_info(:phonic_audio_tick, state) do
    next = input_tick(state)
    {deadline, delay} = Pacer.next(next.deadline, 20_000)
    Process.send_after(self(), :phonic_audio_tick, delay)
    {:noreply, %{next | deadline: deadline}}
  end

  def handle_info({:phonic_interruption_timeout, token}, state) do
    next =
      if state.interruption == token and state.output_blocked,
        do: fail(state, :interruption_not_cleared),
        else: state

    {:noreply, next}
  end

  def handle_info({:phonic_response_timeout, token}, %{response_watch: %{token: token}} = state),
    do: {:noreply, fail(state, :response_timeout)}

  def handle_info({:phonic_response_timeout, _old_token}, state), do: {:noreply, state}

  def handle_info({:phonic_ack_timeout, id, token}, state) do
    case state.acknowledgments[id] do
      %{token: ^token, command_id: command} ->
        emit(state, :context_rejected, %{outcome: :unknown}, command)
        {:noreply, cancel_timer(state, :acknowledgments, id)}

      _old_timer ->
        {:noreply, state}
    end
  end

  def handle_info({:phonic_tool_timeout, id, token}, state) do
    case state.tool_timers[id] do
      %{token: ^token} ->
        {_change, calls} = Calls.expire(state.calls, id)
        next = state |> cancel_timer(:tool_timers, id) |> Map.put(:calls, calls)

        emit(next, :response_status, %{
          status: :delayed,
          cause: :tool_timeout,
          evidence: :local_observation
        })

        {:noreply, next}

      _old_timer ->
        {:noreply, state}
    end
  end

  def handle_info(message, %{socket: socket} = state) when not is_nil(socket),
    do: {:noreply, WebSocketConnection.consume(state, message, &frame/2, &fail/2)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timers(state)
    Audio.close(state.audio)
    WebSocketConnection.close(state.socket)
  end

  defp submit_context(state, id, {:context, update}) do
    case Calls.context(state.calls, update.delegation_id, update.content) do
      {:ok, command, calls} ->
        next = %{
          state
          | calls: calls,
            continuation?: state.continuation? or update.kind == :speakable
        }

        next = transmit(next, command)

        next =
          if next.status == :ready do
            emit(next, :context_submitted, %{outcome: :unconfirmed, evidence: :socket_write}, id)
            arm_acknowledgment(next, command, id)
          else
            next
          end

        {:reply, submission_reply(next), continue_response(next)}

      error ->
        {:reply, error, state}
    end
  end

  defp arm_acknowledgment(state, %{type: "tool_call_output", tool_call_id: call}, command) do
    state
    |> cancel_timer(:tool_timers, call)
    |> arm_timer(:acknowledgments, call, :phonic_ack_timeout, state.acknowledgment_timeout_ms, %{
      command_id: command
    })
  end

  defp arm_acknowledgment(state, _command, _id), do: state

  defp submission_reply(%{status: :closed}),
    do: Error.tuple(:closed, "Context transmission outcome is unknown", %{outcome: :unknown})

  defp submission_reply(_state), do: :ok

  # Async tool output only adds context; it does not request speech. A result
  # can arrive through a late association after an earlier reply consumed the
  # speakable continuation. Resume once per result in this caller turn. The
  # retained call limit also bounds this set; duplicate associations must not
  # create a generate_reply/delegation feedback loop.
  defp association_continuation(
         state,
         %{
           status: :associated,
           task_status: :completed,
           result_delivery: delivery,
           result: result
         }
       )
       when delivery in [:awaiting_provider, :accepted, :unconfirmed, :unknown] and
              is_binary(result) and result != "" do
    if MapSet.member?(state.associated_results, result) do
      state
    else
      %{
        state
        | continuation?: true,
          associated_results: MapSet.put(state.associated_results, result)
      }
    end
  end

  defp association_continuation(state, %{status: :rejected}),
    do: %{state | continuation?: true}

  defp association_continuation(state, _outcome), do: state

  defp continue_response(
         %{
           status: :ready,
           continuation?: true,
           response_watch: nil,
           caller_speaking: false,
           auto_response_pending: false,
           speech: :idle,
           inbound: %{bytes: 0},
           output_blocked: false
         } = state
       ) do
    token = make_ref()

    timer =
      Process.send_after(self(), {:phonic_response_timeout, token}, state.response_timeout_ms)

    transmit(
      %{state | continuation?: false, response_watch: %{token: token, timer: timer}},
      Protocol.respond()
    )
  end

  defp continue_response(state), do: state

  defp frame(_frame, %{status: :closed} = state), do: state
  defp frame(:open, state), do: transmit(%{state | status: :starting}, state.config)

  defp frame({kind, json}, state) when kind in [:text, :binary],
    do: WebSocketConnection.json(state, json, &event/2, &fail/2)

  defp frame({:ping, bytes}, state), do: wire(state, {:pong, bytes})
  defp frame({:close, _code, _reason}, state), do: fail(state, :socket_closed)
  defp frame({:error, _error}, state), do: fail(state, :malformed_frame)
  defp frame(_frame, state), do: state

  defp event(%{"type" => "ready_to_start_conversation"}, %{status: :starting} = state) do
    next = %{state | status: :ready, deadline: now()}
    emit(next, :ready, %{capabilities: Protocol.capabilities(), format: state.init.audio_format})
    emit(next, :provider_speech, %{state: :idle})
    send(self(), :phonic_audio_tick)
    next
  end

  defp event(%{"type" => "conversation_created", "conversation_id" => id}, state)
       when is_binary(id) and byte_size(id) in 1..256,
       do: %{state | conversation_id: id}

  defp event(%{"type" => "error", "error" => %{"code" => "data_retention_not_allowed"}}, state),
    do: fail(state, :retention_not_allowed)

  defp event(%{"type" => "error"}, state), do: fail(state, :provider_rejected)

  defp event(_event, %{status: status} = state) when status != :ready, do: state

  defp event(%{"type" => "user_started_speaking"}, state) do
    state = %{
      state
      | caller_speaking: true,
        auto_response_pending: true,
        associated_results: MapSet.new()
    }

    interrupt(state)
  end

  defp event(%{"type" => "interrupted_response"}, state), do: interrupt(state)

  defp event(%{"type" => "user_finished_speaking"}, state) do
    state = %{state | caller_speaking: false}
    if state.auto_response_pending, do: watch_response(state), else: state
  end

  defp event(%{"type" => "input_text", "text" => text}, state)
       when is_binary(text) and byte_size(text) <= 16_384 do
    if String.trim(text) != "" do
      emit(state, :transcript_delta, %{
        speaker: :user,
        delta: String.trim(text) <> " ",
        start_ms: nil,
        end_ms: nil,
        timing: :unavailable
      })
    end

    state
  end

  defp event(%{"type" => "assistant_started_speaking"}, state) do
    state = clear_response_watch(state)

    speech(
      %{
        state
        | caption_id: ID.new(),
          accepting_output?: true,
          interrupted?: false,
          auto_response_pending: false
      },
      :speaking
    )
  end

  defp event(%{"type" => "assistant_finished_speaking"}, %{speech: :idle} = state), do: state

  defp event(%{"type" => type}, state)
       when type in ["assistant_finished_speaking", "assistant_chose_not_to_respond"] do
    state
    |> clear_response_watch()
    |> Map.merge(%{accepting_output?: false, auto_response_pending: false, caption_id: nil})
    |> speech(:idle)
    |> continue_response()
  end

  defp event(%{"type" => "audio_chunk"}, %{accepting_output?: false} = state), do: state

  defp event(%{"type" => "audio_chunk", "audio" => encoded, "text" => text}, state)
       when is_binary(encoded) and byte_size(encoded) <= 1_000_000 and
              is_binary(text) and byte_size(text) <= 16_384 do
    with {:ok, pcm} <- Base.decode64(encoded),
         true <- rem(byte_size(pcm), 2) == 0,
         {bytes, audio} <- Audio.output(state.audio, pcm),
         {:ok, {queue, sequence}} <-
           OutputBuffer.push(state.inbound, bytes, state.init, state.sequence, now()) do
      if text != "" do
        emit(state, :transcript_delta, %{
          speaker: :assistant,
          delta: text,
          segment_id: state.caption_id,
          start_ms: nil,
          end_ms: nil,
          timing: :unavailable
        })
      end

      OutputBuffer.notify(%{state | inbound: queue, sequence: sequence, audio: audio})
    else
      {:error, %Error{} = error} -> fail(state, error.code)
      _invalid -> fail(state, :invalid_audio)
    end
  end

  defp event(%{"type" => "tool_call"} = call, state) do
    case Calls.admit(state.calls, call) do
      {:new, args, calls} ->
        id = call["tool_call_id"]

        emit(state, :delegation_requested, %{
          id: id,
          target: :client,
          offset_ms: nil,
          arguments: args
        })

        state = %{state | calls: calls}
        # An automatic turn can consist solely of this tool call, with no
        # assistant speech boundary. It is progress, not an outstanding speech
        # response. Let the later result/association request its continuation;
        # do not generate before that output has been supplied.
        state =
          if state.caller_speaking,
            do: state,
            else: clear_response_watch(%{state | auto_response_pending: false})

        arm_timer(state, :tool_timers, id, :phonic_tool_timeout, state.tool_timeout_ms, %{})

      {:duplicate, _calls} ->
        state

      {:error, error} ->
        fail(state, error.code)
    end
  end

  defp event(%{"type" => "tool_call_output_processed", "tool_call_id" => id} = event, state)
       when is_binary(id) and byte_size(id) in 1..256 do
    if event["timed_out"] in [nil, true, false] and
         (is_nil(event["error_message"]) or is_binary(event["error_message"])),
       do: acknowledge(state, id, event),
       else: fail(state, :invalid_acknowledgment)
  end

  defp event(%{"type" => "tool_call_interrupted", "tool_call_id" => id}, state) do
    {change, calls} = Calls.cancel(state.calls, id)

    if change == :changed,
      do: emit(state, :delegation_cancelled, %{id: id, reason: :provider_cancelled})

    state = %{state | calls: calls} |> cancel_timer(:tool_timers, id)
    reject_acknowledgment(state, id)
  end

  defp event(%{"type" => "assistant_ended_conversation"}, state),
    do: close(state, :provider_ended)

  defp event(%{"type" => type}, state) when type in ["audio_chunk", "input_text"],
    do: fail(state, :invalid_output)

  defp event(_event, state), do: state

  defp acknowledge(state, id, event) do
    timed_out? = event["timed_out"] == true
    rejected? = timed_out? or event["error_message"] not in [nil, ""]

    state =
      if timed_out? do
        {_change, calls} = Calls.expire(state.calls, id)
        %{state | calls: calls} |> cancel_timer(:tool_timers, id)
      else
        state
      end

    case state.acknowledgments[id] do
      %{command_id: command} ->
        if rejected? do
          emit(state, :context_rejected, %{outcome: :unknown}, command)
        else
          emit(state, :context_acknowledged, %{acceptance: :provider_processed}, command)
        end

        cancel_timer(state, :acknowledgments, id)

      _unknown_or_late ->
        state
    end
  end

  defp reject_acknowledgment(state, id) do
    if record = state.acknowledgments[id],
      do: emit(state, :context_rejected, %{outcome: :unknown}, record.command_id)

    cancel_timer(state, :acknowledgments, id)
  end

  defp interrupt(%{interrupted?: true} = state), do: state

  defp interrupt(state) do
    token = state.interruption + 1
    emit(state, :output_interrupted, %{token: token})

    Process.send_after(
      self(),
      {:phonic_interruption_timeout, token},
      state.init.limits.cancellation_timeout_ms
    )

    state = clear_response_watch(state)

    speech(
      %{
        state
        | interruption: token,
          interrupted?: true,
          output_blocked: true,
          caller_speaking: true,
          auto_response_pending: true,
          accepting_output?: false,
          inbound: AudioQueue.clear(state.inbound),
          waiter: nil,
          caption_id: nil,
          audio: Audio.reset(state.audio, :output)
      },
      :idle
    )
  end

  defp speech(%{speech: value} = state, value), do: state

  defp speech(state, value) do
    emit(state, :provider_speech, %{state: value})
    emit(state, :provider_activity, %{state: if(value == :idle, do: :idle, else: :in_progress)})
    %{state | speech: value}
  end

  defp input_tick(%{status: :ready} = state) do
    size = AudioFormat.bytes_for_ms(state.init.audio_format, 20)
    {data, queue} = AudioQueue.take_bytes(state.outbound, size)
    silence = AudioFormat.silence(state.init.audio_format, 20)
    bytes = data <> binary_part(silence, 0, size - byte_size(data))
    {pcm, audio} = Audio.input(state.audio, bytes)
    state = %{state | outbound: queue, audio: audio}
    if pcm == <<>>, do: state, else: transmit(state, Protocol.audio(pcm))
  end

  defp input_tick(state), do: state

  defp accept_input(%{muted: true} = state, _frame), do: {:reply, :ok, state}

  defp accept_input(state, frame) do
    case AudioQueue.push(state.outbound, frame) do
      {:ok, queue} -> {:reply, :ok, %{state | outbound: queue}}
      error -> {:reply, error, state}
    end
  end

  defp transmit(state, command), do: WebSocketConnection.command(state, command, &fail/2)
  defp wire(state, frame), do: WebSocketConnection.write(state, frame, &fail/2)

  defp arm_timer(state, field, id, kind, timeout, record) do
    token = make_ref()
    timer = Process.send_after(self(), {kind, id, token}, timeout)
    put_in(state[field][id], Map.merge(record, %{token: token, timer: timer}))
  end

  defp cancel_timer(state, field, id) do
    if record = state[field][id], do: Process.cancel_timer(record.timer)
    Map.update!(state, field, &Map.delete(&1, id))
  end

  defp clear_response_watch(%{response_watch: nil} = state), do: state

  defp clear_response_watch(state) do
    Process.cancel_timer(state.response_watch.timer)
    %{state | response_watch: nil}
  end

  defp watch_response(%{response_watch: watch} = state) when not is_nil(watch), do: state

  defp watch_response(state) do
    token = make_ref()

    timer =
      Process.send_after(self(), {:phonic_response_timeout, token}, state.response_timeout_ms)

    %{state | response_watch: %{token: token, timer: timer}}
  end

  defp cancel_timers(state) do
    Enum.each(
      Map.values(state.tool_timers) ++ Map.values(state.acknowledgments),
      &Process.cancel_timer(&1.timer)
    )

    clear_response_watch(state)
  end

  defp fail(%{status: :closed} = state, _reason), do: state

  defp fail(state, reason) do
    if reason in [:output_overflow, :output_stale],
      do:
        emit(state, :audio_discontinuity, %{cause: reason, discarded_bytes: state.inbound.bytes})

    emit(state, :failed, %{
      error: Error.new(:adapter_failed, "Phonic provider failed", %{reason: reason})
    })

    close(state, reason)
  end

  defp close(%{status: :closed} = state, _reason), do: state

  defp close(state, reason) do
    state = cancel_timers(state)
    WebSocketConnection.close(state.socket)
    Audio.close(state.audio)

    Enum.each(state.acknowledgments, fn {_id, record} ->
      emit(state, :context_rejected, %{outcome: :unknown}, record.command_id)
    end)

    emit(state, :closed, %{reason: reason, finalized?: false})

    %{
      state
      | status: :closed,
        key: nil,
        config: nil,
        socket: nil,
        audio: nil,
        waiter: nil,
        tool_timers: %{},
        acknowledgments: %{},
        inbound: AudioQueue.clear(state.inbound),
        outbound: AudioQueue.clear(state.outbound)
    }
  end

  defp emit(state, type, payload, id \\ nil),
    do: Event.emit(state.init, :provider, type, payload, command_id: id)

  defp now, do: System.monotonic_time(:microsecond)
end
