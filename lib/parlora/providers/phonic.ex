defmodule Parlora.Providers.Phonic do
  @moduledoc """
  Phonic-1 speech-to-speech with application-owned async backend work.

  Caller transcripts are word fragments with unavailable timestamps. Speech
  boundaries delimit assistant captions and interruption epochs. Speakable
  updates wait locally for the current turn and receive queue drain. By default,
  native busy mode owns correlated tool-result speech, with listening backchannels,
  pre-tool acknowledgments, normal speech speed and tuned speech detection. Apps can
  override individual provider options. `wait_for_response: false` keeps concurrent
  voice tools available and uses explicit result replies instead. Backend validation
  and execution remain application-owned.
  Duplicate association routes do not schedule another manual reply. Native tool
  outputs retain current verified facts and an instruction against repetition.
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

  alias Parlora.Providers.Phonic.{
    Audio,
    Calls,
    Connection,
    Correlation,
    Options,
    Protocol,
    Responses
  }

  @doc """
  Returns the provider's default options without credentials or app-specific data.

  Pass overrides directly in the provider tuple; startup merges and validates them.
  Disabling backchannels also removes inherited aggressiveness. Supplying an
  explicit aggressiveness while disabling backchannels is rejected.
  """
  @spec default_options() :: keyword()
  def default_options, do: Options.defaults()

  @impl true
  def audio_limits(format \\ %AudioFormat{}), do: OutputBuffer.burst_limits(format, 20_000)

  @impl true
  def resolve_delegation(pid, id, outcome, metadata),
    do: Parlora.Adapter.call(pid, {:resolve_delegation, id, outcome, metadata})

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
      native_busy?: hd(config.tools).wait_for_response,
      busy_call_id: nil,
      busy_task: nil,
      native_handoff?: false,
      associated_results: MapSet.new(),
      covered_results: MapSet.new(),
      pending_contexts: [],
      reply_active?: false,
      reply_spoke?: false,
      turn_delegated?: false,
      tool_timers: %{},
      acknowledgments: %{},
      tool_timeout_ms: config.tools |> hd() |> Map.fetch!(:tool_call_output_timeout_ms),
      acknowledgment_timeout_ms: Options.get(options, :acknowledgment_timeout_ms),
      response_timeout_ms: Options.get(options, :response_timeout_ms),
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
      speech_ends_pending: 0,
      caption_id: nil,
      caller_segment_id: nil,
      speech_user_segment_id: nil,
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
  def handle_call({:close, _id, reason}, _from, state),
    do: {:reply, :ok, close_state(state, reason, true)}

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
    queued? = Enum.any?(state.pending_contexts, &(&1.command[:tool_call_id] == id))

    if state.busy_call_id == id and Correlation.hold?(outcome, queued?),
      do: {:reply, :ok, continue_response(state)},
      else: complete_delegation(state, id, outcome)
  end

  def handle_call(
        {:resolve_delegation, id, %{status: :associated} = outcome, metadata},
        from,
        %{native_busy?: true, busy_call_id: id} = state
      ) do
    with :ok <- Correlation.validate(metadata, state.init.generation),
         {:ok, entries, scope, obsolete} <- Correlation.bind(state.pending_contexts, id, metadata) do
      Enum.each(
        obsolete,
        &emit(state, :context_rejected, %{outcome: :unknown, reason: :superseded}, &1.id)
      )

      next = %{
        state
        | pending_contexts: entries,
          busy_task: scope,
          continuation?: Enum.any?(entries, &is_binary(&1.content))
      }

      handle_call({:resolve_delegation, id, outcome}, from, next)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resolve_delegation, id, outcome, _metadata}, from, state),
    do: handle_call({:resolve_delegation, id, outcome}, from, state)

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

        {:noreply, if(state.busy_call_id == id, do: fail(next, :tool_timeout), else: next)}

      _old_timer ->
        {:noreply, state}
    end
  end

  def handle_info(message, %{socket: socket} = state) when not is_nil(socket),
    do: {:noreply, WebSocketConnection.consume(state, message, &frame/2, &fail/2)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_timers(state)
    Audio.close(state.audio)
    close_socket(state, reason in [:normal, :shutdown] or match?({:shutdown, _}, reason))
  end

  defp complete_delegation(state, id, outcome) do
    case Calls.complete(state.calls, id, outcome) do
      {:ok, command, calls} ->
        resolve_output(state, id, outcome, command, calls)

      {terminal, _calls} when terminal in [:duplicate, :expired] ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  defp submit_context(state, id, {:context, update}) do
    case Correlation.context(state.calls, update, state.busy_call_id, state.busy_task) do
      {:ok, command, calls, scope} ->
        state = %{state | busy_task: scope}

        if update.kind == :speakable do
          entry = %{command: command, id: id, update: update, content: update.content}
          enqueue_context(state, calls, entry, true)
        else
          next = %{state | calls: calls} |> transmit(command) |> submitted(id, command)
          {:reply, submission_reply(next), continue_response(next)}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp submitted(%{status: :ready} = state, id, command) when not is_nil(id) do
    emit(state, :context_submitted, %{outcome: :unconfirmed, evidence: :socket_write}, id)
    arm_acknowledgment(state, command, id)
  end

  defp submitted(state, _id, _command), do: state

  defp resolve_output(
         state,
         id,
         %{
           status: :associated,
           task_status: :completed,
           result_delivery: delivery,
           result: content
         },
         command,
         calls
       )
       when delivery in [:awaiting_provider, :accepted, :unconfirmed, :unknown] and
              is_binary(content) and content != "" do
    speak? = association_speaks?(state, id, content)
    # Manual duplicate routes leave speech to the original update. A native
    # pending call still needs its verified facts even after a prior reply ended.
    command = Responses.association(command, content, speak?, state.native_busy?)

    update = association_update(state, id, if(speak?, do: content))
    entry = %{command: command, id: nil, update: update, content: if(speak?, do: content)}

    case enqueue_context(state, calls, entry, speak?) do
      {:reply, :ok, next} ->
        next =
          if speak?,
            do: %{next | associated_results: MapSet.put(next.associated_results, content)},
            else: next

        {:reply, :ok, cancel_timer(next, :tool_timers, id)}

      error ->
        error
    end
  end

  defp resolve_output(state, id, outcome, command, calls),
    do: resolve_terminal_output(state, id, outcome, command, calls)

  defp association_speaks?(state, id, content) do
    not MapSet.member?(state.covered_results, content) or
      (state.calls.records[id][:reply_yielded?] and
         not MapSet.member?(state.associated_results, content))
  end

  defp association_update(%{native_busy?: true, busy_task: scope}, id, content)
       when is_map(scope) and is_binary(content),
       do: Map.merge(scope, %{delegation_id: id, kind: :speakable, content: content})

  defp association_update(_, _, _), do: nil

  defp resolve_terminal_output(state, id, %{status: :rejected} = outcome, command, calls) do
    entry = %{
      command: command,
      id: nil,
      update: nil,
      content: "Application delegation rejected: " <> JSON.encode!(outcome)
    }

    case enqueue_context(state, calls, entry, true) do
      {:reply, :ok, next} -> {:reply, :ok, cancel_timer(next, :tool_timers, id)}
      error -> error
    end
  end

  defp resolve_terminal_output(state, id, _outcome, command, calls) do
    if state.native_busy? do
      entry = %{command: command, id: nil, update: nil, content: nil}
      enqueue_context(state, calls, entry, false)
    else
      next =
        state |> cancel_timer(:tool_timers, id) |> Map.put(:calls, calls) |> transmit(command)

      {:reply, submission_reply(next), continue_response(next)}
    end
  end

  # Keep speakable facts out of an automatic/in-flight turn. Publish them only
  # with the explicit reply that owns them, rather than guess what speech meant.
  defp enqueue_context(state, calls, entry, speak?) do
    if length(state.pending_contexts) >= state.init.limits.max_records do
      {:reply, Error.tuple(:backpressure, "Pending Phonic context capacity exhausted"), state}
    else
      state = supersede_pending(state, entry)

      next = %{
        state
        | calls: calls,
          pending_contexts: state.pending_contexts ++ [entry],
          continuation?: state.continuation? or speak?,
          covered_results:
            if(entry.content,
              do: MapSet.put(state.covered_results, entry.content),
              else: state.covered_results
            )
      }

      {:reply, submission_reply(next), continue_response(next)}
    end
  end

  defp supersede_pending(state, %{update: %{task_id: task, task_revision: revision}} = current)
       when is_binary(task) and is_integer(revision) do
    {obsolete, keep} =
      Enum.split_with(state.pending_contexts, fn
        %{update: %{task_id: ^task, task_revision: old}} when is_integer(old) -> old < revision
        _ -> false
      end)

    Enum.reduce(obsolete, %{state | pending_contexts: keep}, fn entry, acc ->
      emit(acc, :context_rejected, %{outcome: :unknown, reason: :superseded}, entry.id)

      retire_superseded(acc, entry, current)
    end)
  end

  defp supersede_pending(state, _entry), do: state

  defp retire_superseded(
         state,
         %{command: %{type: "tool_call_output", tool_call_id: call}} = entry,
         current
       ) do
    cond do
      Responses.replaces_unsent?(entry, current, state.busy_call_id) ->
        state

      state.native_busy? ->
        terminal = %{
          entry
          | command: Protocol.result(call, %{status: :superseded}),
            id: nil,
            update: nil,
            content: nil
        }

        %{state | pending_contexts: [terminal | state.pending_contexts]}

      true ->
        transmit(state, Protocol.result(call, %{status: :superseded}))
    end
  end

  defp retire_superseded(state, _entry, _current), do: state

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

  defp continue_response(
         %{
           status: :ready,
           response_watch: nil,
           caller_speaking: false,
           auto_response_pending: false,
           speech: :idle,
           inbound: %{bytes: 0},
           output_blocked: false
         } = state
       ) do
    flush_context(state)
  end

  defp continue_response(state), do: state

  defp flush_context(state) do
    case Responses.plan(state.pending_contexts, state.busy_call_id) do
      {:manual, entries} -> flush_manual(state, entries)
      {:native, entry, command, rest} -> flush_native(state, entry, command, rest)
      :wait -> state
    end
  end

  defp flush_native(state, entry, command, rest) do
    next = transmit(state, command)

    if next.status == :ready do
      rest = Responses.closed(rest, command.tool_call_id)

      next = %{
        next
        | pending_contexts: rest,
          busy_call_id: nil,
          busy_task: nil,
          native_handoff?: true,
          calls: Calls.sent_output(next.calls, command.tool_call_id, command.output),
          continuation?: Enum.any?(rest, &is_binary(&1.content)),
          reply_active?: true,
          reply_spoke?: false
      }

      next
      |> submitted(entry.id, command)
      |> cancel_timer(:tool_timers, command.tool_call_id)
      |> watch_response()
    else
      next
    end
  end

  defp flush_manual(state, entries) do
    state =
      Enum.reduce_while(entries, state, fn entry, acc ->
        command = pending_command(acc, entry)
        next = transmit(acc, command)

        if next.status == :ready do
          next = %{next | pending_contexts: tl(next.pending_contexts)}
          {:cont, submitted(next, entry.id, command)}
        else
          {:halt, next}
        end
      end)

    if state.continuation? and state.status == :ready do
      contents = entries |> Enum.map(& &1.content) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      request_reply(
        %{state | reply_active?: true, reply_spoke?: false},
        contents
      )
    else
      state
    end
  end

  defp pending_command(state, %{command: %{type: "tool_call_output", tool_call_id: id}} = entry) do
    if state.calls.records[id].status == :expired and entry.content,
      do: Protocol.text(entry.content),
      else: entry.command
  end

  defp pending_command(_state, entry), do: entry.command

  defp finish_reply(state), do: %{state | reply_active?: false, reply_spoke?: false}

  defp request_reply(state, contents) do
    token = make_ref()

    timer =
      Process.send_after(self(), {:phonic_response_timeout, token}, state.response_timeout_ms)

    content = Enum.join(contents, "\n\n")
    # Every update is already present in context. Keep the optional per-reply
    # hint bounded when several independent updates are released together.
    hint = if content != "" and byte_size(content) <= 16_000, do: content

    transmit(
      %{state | continuation?: false, response_watch: %{token: token, timer: timer}},
      Protocol.respond(hint)
    )
  end

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
        caller_segment_id: ID.new(),
        auto_response_pending: true,
        associated_results: MapSet.new(),
        covered_results:
          MapSet.new(Enum.map(state.pending_contexts, & &1.content) |> Enum.reject(&is_nil/1)),
        turn_delegated?: false
    }

    caller_speech(state, :started)
    interrupt(state)
  end

  defp event(%{"type" => "interrupted_response"}, state), do: interrupt(state)

  defp event(%{"type" => "user_finished_speaking"}, state) do
    caller_speech(state, :finished)
    state = %{state | caller_speaking: false}

    cond do
      state.turn_delegated? ->
        continue_response(clear_response_watch(%{state | auto_response_pending: false}))

      state.busy_call_id != nil and not state.reply_active? ->
        continue_response(clear_response_watch(%{state | auto_response_pending: false}))

      state.auto_response_pending ->
        watch_response(state)

      true ->
        continue_response(state)
    end
  end

  defp event(%{"type" => "input_cancelled"}, state) do
    caller_speech(state, :cancelled)

    state =
      if state.auto_response_pending and not state.reply_active?,
        do: clear_response_watch(state),
        else: state

    continue_response(%{state | caller_speaking: false, auto_response_pending: false})
  end

  defp event(%{"type" => "input_text", "text" => text}, state)
       when is_binary(text) and byte_size(text) <= 16_384 do
    text = String.trim(text)

    cond do
      Regex.match?(~r/[\p{L}\p{N}]/u, text) ->
        emit(state, :transcript_delta, %{
          speaker: :user,
          delta: text <> " ",
          segment_id: state.caller_segment_id,
          start_ms: nil,
          end_ms: nil,
          timing: :unavailable
        })

      text != "" ->
        emit(state, :extension, %{
          kind: :transcript_discarded,
          cause: :no_lexical_content,
          speaker: :user,
          delta: text,
          segment_id: state.caller_segment_id
        })

      true ->
        :ok
    end

    state
  end

  # In this mode the tool is dispatched after the pre-tool speech. Ignore
  # stray speech in the same turn until a native result or a requested reply.
  defp event(
         %{"type" => type},
         %{
           config: %{
             tools: [
               %{wait_for_speech_before_tool_call: true, forbid_speech_after_tool_call: true}
             ]
           },
           busy_call_id: call,
           turn_delegated?: true,
           reply_active?: false
         } = state
       )
       when is_binary(call) and type in ["assistant_started_speaking", "audio_chunk"],
       do: state

  defp event(
         %{"type" => "assistant_started_speaking"},
         %{speech_ends_pending: count, init: %{limits: %{max_records: limit}}} = state
       )
       when count >= limit,
       do: fail(state, :speech_boundary_overflow)

  defp event(%{"type" => "assistant_started_speaking"}, state) do
    start_speech(state, state.speech_ends_pending + 1)
  end

  defp event(
         %{"type" => "assistant_finished_speaking"},
         %{speech_ends_pending: count} = state
       )
       when count > 1,
       do: %{state | speech_ends_pending: count - 1}

  defp event(%{"type" => "assistant_finished_speaking"}, %{speech: :idle} = state),
    do: %{state | speech_ends_pending: 0}

  defp event(
         %{"type" => "assistant_finished_speaking"},
         %{speech_user_segment_id: segment} = state
       )
       when is_binary(segment) do
    state
    |> Map.merge(%{
      accepting_output?: false,
      speech_ends_pending: 0,
      caption_id: nil,
      speech_user_segment_id: nil,
      native_handoff?: false
    })
    |> speech(:idle)
    |> continue_response()
  end

  defp event(%{"type" => type}, state)
       when type in ["assistant_finished_speaking", "assistant_chose_not_to_respond"] do
    state
    |> clear_response_watch()
    |> finish_reply()
    |> Map.merge(%{
      accepting_output?: false,
      auto_response_pending: false,
      speech_ends_pending: 0,
      caption_id: nil,
      speech_user_segment_id: nil,
      native_handoff?: false
    })
    |> speech(:idle)
    |> continue_response()
  end

  defp event(
         %{"type" => "audio_chunk", "text" => text} = event,
         %{
           accepting_output?: false,
           native_handoff?: true,
           interrupted?: false,
           output_blocked: false
         } = state
       )
       when is_binary(text) and byte_size(text) in 1..16_384 do
    state = start_speech(state, max(1, state.speech_ends_pending))
    event(event, state)
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
          overlaps_user_segment_id: state.speech_user_segment_id,
          start_ms: nil,
          end_ms: nil,
          timing: :unavailable
        })
      end

      OutputBuffer.notify(%{state | inbound: queue, sequence: sequence, audio: audio})
      |> Map.update!(
        :reply_spoke?,
        &(&1 or (state.reply_active? and (text != "" or pcm != <<>>)))
      )
    else
      {:error, %Error{} = error} -> fail(state, error.code)
      _invalid -> fail(state, :invalid_audio)
    end
  end

  defp event(%{"type" => "tool_call"} = call, state) do
    case Calls.admit(state.calls, call) do
      {:new, args, calls} ->
        if state.busy_call_id,
          do: fail(state, :unexpected_concurrent_tool),
          else: admit_tool(state, call["tool_call_id"], args, calls)

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

    state =
      if state.busy_call_id == id, do: %{state | busy_call_id: nil, busy_task: nil}, else: state

    state = %{state | calls: calls} |> cancel_timer(:tool_timers, id)
    state |> cancel_pending(id) |> reject_acknowledgment(id) |> continue_response()
  end

  defp event(%{"type" => "assistant_ended_conversation"}, state),
    do: close_state(state, :provider_ended)

  defp event(%{"type" => type}, state) when type in ["audio_chunk", "input_text"],
    do: fail(state, :invalid_output)

  defp event(_event, state), do: state

  defp start_speech(state, pending_ends) do
    overlap = if state.caller_speaking, do: state.caller_segment_id
    state = if overlap, do: state, else: clear_response_watch(state)

    speech(
      %{
        state
        | caption_id: ID.new(),
          speech_ends_pending: pending_ends,
          speech_user_segment_id: overlap,
          accepting_output?: true,
          interrupted?: false,
          native_handoff?: false,
          auto_response_pending: overlap != nil and state.auto_response_pending
      },
      :speaking
    )
  end

  defp admit_tool(state, id, args, calls) do
    emit(state, :delegation_requested, %{
      id: id,
      target: :client,
      offset_ms: nil,
      arguments: args
    })

    calls =
      put_in(
        calls.records[id][:reply_yielded?],
        state.reply_active? and (state.native_busy? or not state.reply_spoke?)
      )

    state = settle_yielded_reply(state, state.native_busy? or calls.records[id][:reply_yielded?])

    state = %{
      state
      | calls: calls,
        turn_delegated?: true,
        busy_call_id: if(state.native_busy?, do: id),
        native_handoff?: state.native_busy?
    }

    # An automatic turn can consist solely of this tool call, with no
    # assistant speech boundary. It is progress, not an outstanding speech
    # response. Let the later result/association request its continuation;
    # do not generate before that output has been supplied.
    state =
      if state.caller_speaking,
        do: state,
        else: clear_response_watch(%{state | auto_response_pending: false})

    arm_timer(state, :tool_timers, id, :phonic_tool_timeout, state.tool_timeout_ms, %{})
  end

  # Retire local output without consuming native speech ends still in flight.
  # Manual mode retains its existing empty-generation handoff behavior.
  defp settle_yielded_reply(state, true) do
    state
    |> finish_reply()
    |> Map.merge(%{
      accepting_output?: false,
      caption_id: nil,
      speech_user_segment_id: nil,
      speech_ends_pending: if(state.native_busy?, do: state.speech_ends_pending, else: 0)
    })
    |> speech(:idle)
  end

  defp settle_yielded_reply(state, _yielded), do: state

  defp acknowledge(state, id, event) do
    timed_out? = event["timed_out"] == true
    rejected? = timed_out? or event["error_message"] not in [nil, ""]

    state =
      if timed_out? do
        {_change, calls} = Calls.expire(state.calls, id)
        next = %{state | calls: calls} |> cancel_timer(:tool_timers, id)

        if next.busy_call_id == id,
          do: watch_response(%{next | busy_call_id: nil, busy_task: nil}),
          else: next
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

  defp cancel_pending(state, id) do
    {cancelled, keep} = Enum.split_with(state.pending_contexts, &(pending_call(&1) == id))

    for entry <- cancelled,
        entry.id != nil,
        do:
          emit(
            state,
            :context_rejected,
            %{outcome: :unknown, reason: :provider_cancelled},
            entry.id
          )

    %{state | pending_contexts: keep, continuation?: Enum.any?(keep, & &1.content)}
  end

  defp pending_call(%{command: %{type: "tool_call_output", tool_call_id: id}}), do: id
  defp pending_call(%{update: %{delegation_id: id}}), do: id
  defp pending_call(_), do: nil

  defp caller_speech(state, value) do
    emit(state, :extension, %{
      kind: :caller_speech,
      state: value,
      segment_id: state.caller_segment_id
    })
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
          speech_user_segment_id: nil,
          speech_ends_pending: 0,
          native_handoff?: false,
          reply_active?: false,
          reply_spoke?: false,
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

    close_state(state, reason)
  end

  defp close_state(state, reason, graceful? \\ false)

  defp close_state(%{status: :closed} = state, _reason, _graceful?), do: state

  defp close_state(state, reason, graceful?) do
    state = cancel_timers(state)
    close_socket(state, graceful?)
    Audio.close(state.audio)

    Enum.each(state.acknowledgments, fn {_id, record} ->
      emit(state, :context_rejected, %{outcome: :unknown}, record.command_id)
    end)

    for entry <- state.pending_contexts,
        entry.id != nil,
        do: emit(state, :context_rejected, %{outcome: :unknown}, entry.id)

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
        pending_contexts: [],
        speech_ends_pending: 0,
        covered_results: MapSet.new(),
        associated_results: MapSet.new(),
        inbound: AudioQueue.clear(state.inbound),
        outbound: AudioQueue.clear(state.outbound)
    }
  end

  defp close_socket(state, true),
    do: Connection.close(state.socket, state.init.limits.shutdown_timeout_ms)

  defp close_socket(state, false), do: WebSocketConnection.close(state.socket)

  defp emit(state, type, payload, id \\ nil),
    do: Event.emit(state.init, :provider, type, payload, command_id: id)

  defp now, do: System.monotonic_time(:microsecond)
end
