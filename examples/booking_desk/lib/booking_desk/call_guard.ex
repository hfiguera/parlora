defmodule BookingDesk.CallGuard do
  alias BookingDesk.CallGuard.{Announcement, Classifier, NativeReply}
  @moduledoc "Per-call, fail-closed task gate, scope redirects and caller-conduct lifecycle."
  use GenServer, restart: :temporary
  alias Parlora.ContextUpdate

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def bind(pid, session), do: GenServer.call(pid, {:bind, session})
  def observer(pid), do: GenServer.call(pid, :observer)
  def check(pid, snapshot), do: GenServer.call(pid, {:check, snapshot})

  def init(opts) do
    {:ok,
     %{
       session: nil,
       session_id: nil,
       sink: Keyword.fetch!(opts, :event_sink),
       outer_observer: Keyword.get(opts, :audio_observer),
       credits: :atomics.new(2, []),
       reported_drops: 0,
       transport: Keyword.get(opts, :transport, Parlora),
       instruction_updates: Keyword.get(opts, :instruction_updates, false),
       native_result_replies: Keyword.get(opts, :native_result_replies, false),
       native_reply: %NativeReply{},
       evaluator: Keyword.get(opts, :evaluator, &Classifier.classify/1),
       debounce_ms: Keyword.get(opts, :debounce_ms, 650),
       timeout_ms: Keyword.get(opts, :timeout_ms, 2_500),
       quiet_ms: Keyword.get(opts, :quiet_ms, 1_500),
       delivery_ms: Keyword.get(opts, :delivery_ms, 20_000),
       max_evaluations: Keyword.get(opts, :max_evaluations, 48),
       evaluations: 0,
       key: nil,
       source: nil,
       verdict: nil,
       timer: nil,
       job: nil,
       serial: 0,
       abuse: 0,
       off_topic: 0,
       emergency: false,
       closing: nil,
       announcement: nil,
       speech: :unknown
     }}
  end

  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  def handle_call({:bind, session}, _, s) do
    Process.monitor(session)
    {:reply, :ok, %{s | session: session}}
  end

  def handle_call(:observer, _, s), do: {:reply, %{pid: self(), credits: s.credits}, s}

  def handle_call({:check, snapshot}, _, s) do
    key = key(snapshot)
    s = %{s | session_id: snapshot.session_id}

    cond do
      s.session == nil ->
        {:reply, :wait, s}

      s.emergency ->
        s =
          if key != nil and elem(key, 0) != elem(s.key, 0) do
            announce(%{s | key: key}, :emergency, true)
          else
            s
          end

        {:reply, :blocked, s}

      key == nil ->
        {:reply, if(s.closing, do: :blocked, else: :allow), s}

      key == s.key ->
        {:reply, gate(s), s}

      true ->
        schedule_check(s, snapshot, key)
    end
  end

  def handle_info({:parlora_event, event} = message, s) do
    if is_pid(s.sink), do: send(s.sink, message)
    s = %{s | native_reply: NativeReply.observe(s.native_reply, event, s.key)}

    s =
      case event do
        %{type: :transcript_delta, payload: %{speaker: :user}} ->
          %{s | serial: s.serial + 1}

        %{type: :transcript_delta, payload: %{speaker: :assistant}} when s.announcement != nil ->
          %{s | announcement: Announcement.caption(s.announcement, event)}

        %{type: :provider_speech, payload: %{state: speech}} ->
          announcement =
            if speech == :speaking and s.speech != :speaking and s.announcement,
              do: Announcement.reset(s.announcement),
              else: s.announcement

          %{s | speech: speech, announcement: announcement}

        _ ->
          s
      end

    {:noreply, s}
  end

  def handle_info({:parlora_audio, direction, at, pcm}, s) do
    :atomics.sub(s.credits, 1, 1)
    s = sync_drops(s)
    forward_audio(s.outer_observer, direction, at, pcm)

    s =
      if direction == :output and s.announcement != nil and audible?(pcm) do
        %{s | announcement: Announcement.audible(s.announcement, now())}
      else
        s
      end

    {:noreply, s}
  end

  def handle_info({:classify, token}, %{timer: {token, _}} = s) do
    if s.evaluations >= s.max_evaluations do
      emit(s, :budget_exhausted)
      {:noreply, announce(%{s | timer: nil, verdict: :blocked}, :unavailable, true)}
    else
      evaluate = s.evaluator
      input = s.source
      session = s.session
      transport = s.transport

      job =
        Task.Supervisor.async_nolink(BookingDesk.GuardTasks, fn ->
          result =
            try do
              evaluate.(input)
            rescue
              _ -> {:error, :unavailable}
            catch
              _, _ -> {:error, :unavailable}
            end

          snapshot = transport.snapshot(session)
          {result, snapshot}
        end)

      timer = Process.send_after(self(), {:guard_timeout, job.ref}, s.timeout_ms)

      {:noreply,
       %{
         s
         | timer: nil,
           evaluations: s.evaluations + 1,
           job: %{task: job, timer: timer, key: s.key, serial: s.serial}
       }}
    end
  end

  def handle_info({:classify, _}, s), do: {:noreply, s}

  def handle_info({ref, {result, snapshot}}, %{job: %{task: %{ref: ref}} = job} = s) do
    Process.cancel_timer(job.timer)
    Process.demonitor(ref, [:flush])
    s = %{s | job: nil}

    if job.key == key(snapshot) and job.key == s.key and job.serial == s.serial do
      {:noreply, apply_result(s, result)}
    else
      emit(s, :stale_classification)
      # A newer policy snapshot will admit a fresh classification. Never apply
      # a warning or release task admission from an obsolete utterance.
      {:noreply, %{s | key: nil, verdict: nil}}
    end
  end

  def handle_info({:guard_timeout, ref}, %{job: %{task: %{ref: ref}}} = s),
    do: {:noreply, announce(%{cancel_job(s) | verdict: :blocked}, :unavailable, true)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{job: %{task: %{ref: ref}}} = s),
    do: {:noreply, announce(%{cancel_job(s) | verdict: :blocked}, :unavailable, true)}

  def handle_info({:DOWN, _, :process, pid, _}, %{session: pid} = s), do: {:stop, :normal, s}

  def handle_info({:guard_tick, token}, %{announcement: %{token: token} = a} = s) do
    drained = playout_drained?(s, a)

    timed_out = now() - a.started >= s.delivery_ms
    settled = s.job == nil and s.timer == nil
    hard_deadline = now() - a.started >= s.delivery_ms + s.debounce_ms + s.timeout_ms + 1_000

    if ((drained or timed_out) and settled) or hard_deadline do
      emit(s, if(drained, do: :software_playout_quiet, else: :message_unconfirmed))

      finish_announcement(s, a, drained)
    else
      Process.send_after(self(), {:guard_tick, token}, 100)
      {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    sync_drops(s)
    cancel_job(s)
    :ok
  end

  defp schedule_check(s, snapshot, key) do
    s = %{cancel_job(s) | native_reply: NativeReply.check(s.native_reply, key)}
    dialogue = BookingDesk.Dialogue.build(snapshot.transcripts, limit: 6)

    source = %{
      dialogue: dialogue,
      latest_user: List.last(Enum.filter(dialogue, &(&1.speaker == :user))).text
    }

    if byte_size(JSON.encode!(source)) > 6_000 do
      s = %{s | key: key, verdict: :blocked}
      {:reply, :blocked, announce(s, :unavailable, true)}
    else
      token = make_ref()
      timer = Process.send_after(self(), {:classify, token}, s.debounce_ms)
      {:reply, :wait, %{s | key: key, source: source, verdict: nil, timer: {token, timer}}}
    end
  end

  defp playout_drained?(s, a),
    do:
      a.heard and a.caption and s.speech != :speaking and
        now() - a.last_voice >= s.quiet_ms and now() - a.started >= s.quiet_ms

  defp finish_announcement(%{closing: reason} = s, _a, _drained) when not is_nil(reason) do
    async(s, fn -> s.transport.close(s.session, :finish) end)
    {:noreply, %{s | announcement: nil}}
  end

  defp finish_announcement(s, a, drained) do
    s = if drained, do: s, else: undo_warning(s, a)
    {:noreply, %{s | announcement: nil}}
  end

  defp undo_warning(s, %{reason: :abuse_warning}), do: %{s | abuse: max(0, s.abuse - 1)}
  defp undo_warning(s, %{reason: :scope_redirect}), do: %{s | off_topic: max(0, s.off_topic - 1)}
  defp undo_warning(s, _), do: s

  defp gate(%{closing: reason}) when reason != nil, do: :blocked
  defp gate(%{verdict: :allowed}), do: :allow
  defp gate(%{verdict: nil}), do: :wait
  defp gate(_), do: :blocked

  defp apply_result(s, {:ok, kind}) when kind in [:emergency, :possible_emergency] do
    # An emergency can override an abuse/off-topic closure while it is draining.
    announce(%{s | emergency: true, closing: nil, verdict: :blocked}, kind, true)
  end

  defp apply_result(%{closing: reason} = s, _) when reason != nil, do: s

  defp apply_result(s, {:ok, :allowed}) do
    emit(s, :allowed)
    %{s | verdict: :allowed}
  end

  defp apply_result(s, {:ok, :abuse}) do
    s = %{s | verdict: :blocked}

    if s.announcement != nil and s.announcement.reason == :abuse_warning do
      s
    else
      s = %{s | abuse: s.abuse + 1}
      announce(s, if(s.abuse == 1, do: :abuse_warning, else: :abuse_close), s.abuse > 1)
    end
  end

  defp apply_result(s, {:ok, :off_topic}) do
    s = %{s | verdict: :blocked}

    cond do
      s.announcement != nil ->
        s

      s.off_topic < 2 and native_reply?(s) ->
        coalesce_boundary(s, :off_topic)

      true ->
        s = %{s | off_topic: s.off_topic + 1}

        announce(
          s,
          if(s.off_topic < 3, do: :scope_redirect, else: :scope_close),
          s.off_topic >= 3
        )
    end
  end

  defp apply_result(s, {:ok, :medical_question}),
    do: announce(%{s | verdict: :blocked}, :medical_redirect, false)

  defp apply_result(s, {:error, :uncertain}) do
    s = %{s | verdict: :blocked}

    if native_reply?(s),
      do: coalesce_boundary(s, :uncertain),
      else: announce(s, :clarify_scope, false)
  end

  defp apply_result(s, _), do: announce(%{s | verdict: :blocked}, :unavailable, true)

  defp native_reply?(s),
    do: s.native_result_replies and NativeReply.active?(s.native_reply, s.key)

  defp coalesce_boundary(s, reason) do
    emit(s, :boundary_coalesced)

    update = %ContextUpdate{
      id: "call-guard-#{System.unique_integer([:positive])}",
      kind: :quiet,
      provider_generation: elem(s.key, 0),
      content:
        "Application call-boundary decision: the latest caller turn is #{reason}. " <>
          "Do not answer unrelated topics or start new work from that turn. " <>
          "Continue the single current verified result or pending question once. " <>
          "Do not repeat a question already spoken. This update requests no extra spoken turn " <>
          "and grants no booking approval or reminder consent. Wait for the caller's answer."
    }

    async(s, fn ->
      current = s.transport.snapshot(s.session)

      cond do
        key(current) != s.key -> emit(s, :stale_boundary_action)
        s.transport.append_context(s.session, update) != :ok -> emit(s, :message_rejected)
        true -> :ok
      end
    end)

    s
  end

  def message(:emergency),
    do:
      "Please hang up and call 911 now for emergency help. I cannot call or transfer you to emergency services. Outside the United States, call your local emergency number. Goodbye."

  def message(:possible_emergency),
    do:
      "If this may be a medical emergency, please hang up and call 911 now, or your local emergency number outside the United States. I cannot contact emergency services for you. Goodbye."

  def message(:abuse_warning),
    do:
      "I can help with appointments, but please stop the abusive language. If it continues, I will end this call. How can I help with your appointment?"

  def message(:abuse_close),
    do: "The abusive language has continued, so I am ending this call. Goodbye."

  def message(:scope_redirect),
    do:
      "I can help with clinic appointments, registration, insurance details and reminders. What would you like to arrange?"

  def message(:scope_close),
    do:
      "This line is for clinic appointments and registration. Since we cannot continue with that, I am ending the call. Goodbye."

  def message(:medical_redirect),
    do:
      "I cannot provide medical advice. Please speak with a qualified medical professional. I can help you arrange an appointment."

  def message(:clarify_scope),
    do:
      "I can help with clinic scheduling and registration. Could you tell me what you need help arranging?"

  def message(:unavailable),
    do:
      "I am unable to handle this request safely right now. If this is a medical emergency, call 911. Please try again later. Goodbye."

  defp announce(s, reason, close?) do
    # Replacing an unfinished lower-priority message does not make it a delivered warning.
    s = undo_warning(s, s.announcement)

    emit(s, reason)
    started = now()
    session = s.session
    transport = s.transport
    generation = elem(s.key, 0)

    state_instruction = emergency_instruction(s)

    update = %ContextUpdate{
      id: "call-guard-#{System.unique_integer([:positive])}",
      kind: :speakable,
      provider_generation: generation,
      content:
        state_instruction <>
          "Application call-boundary decision. Do not continue the previous topic or claim any new backend result. Say this concise message without adding unrelated conversation: " <>
          message(reason)
    }

    async(s, fn -> deliver_announcement(s, session, transport, update, state_instruction) end)

    announcement = Announcement.new(reason, message(reason), generation, started)
    Process.send_after(self(), {:guard_tick, announcement.token}, 100)

    %{
      s
      | closing: if(close?, do: reason),
        announcement: announcement
    }
  end

  defp emergency_instruction(%{emergency: true}) do
    "EMERGENCY CLOSING MODE. This is a clinic scheduling call, not a 911 connection. " <>
      "All new scheduling and patient lookups are blocked for the rest of this call. " <>
      "Do not collect name/DOB or insurance, offer appointments, or say you are pulling a file, checking records or booking. " <>
      "No emergency services have been called or connected. Give the emergency instruction, end with Goodbye, " <>
      "and do not resume ordinary conversation while the application closes the line. "
  end

  defp emergency_instruction(_), do: ""

  defp deliver_announcement(s, session, transport, update, state_instruction) do
    current = transport.snapshot(session)

    if s.emergency or key(current) == s.key do
      update = %{update | provider_generation: current.provider_generation}
      transport.control(session, {:clear_output, :next})
      prepare_emergency_output(s, session, transport, update, state_instruction)

      case transport.append_context(session, update) do
        :ok -> :ok
        _ -> emit(s, :message_rejected)
      end
    else
      emit(s, :stale_boundary_action)
    end
  end

  defp prepare_emergency_output(%{emergency: false}, _, _, _, _), do: :ok

  defp prepare_emergency_output(s, session, transport, update, instruction) do
    # Admission remains blocked even if the provider rejects a control update.
    if transport.control(session, {:input_muted, true}) != :ok, do: emit(s, :input_mute_rejected)
    set_emergency_instruction(s, session, transport, update, instruction)
  end

  defp set_emergency_instruction(%{instruction_updates: false}, _, _, _, _), do: :ok

  defp set_emergency_instruction(s, session, transport, update, instruction) do
    update = %{update | id: update.id <> "-mode", kind: :instruction, content: instruction}
    if transport.append_context(session, update) != :ok, do: emit(s, :instruction_rejected)
  end

  defp async(_s, function), do: Task.Supervisor.start_child(BookingDesk.GuardTasks, function)

  defp emit(s, outcome) do
    metadata = %{outcome: outcome, session_id: s.session_id}

    metadata =
      if s.key do
        Map.merge(metadata, %{provider_generation: elem(s.key, 0), caller_cursor: elem(s.key, 1)})
      else
        metadata
      end

    :telemetry.execute([:booking_desk, :guard, :stop], %{count: 1}, metadata)

    if outcome in [
         :emergency,
         :possible_emergency,
         :abuse_warning,
         :abuse_close,
         :scope_redirect,
         :scope_close,
         :medical_redirect,
         :unavailable
       ] do
      IO.puts("Call guard: #{outcome}")
    end
  end

  defp key(snapshot) do
    case Enum.find(snapshot.transcripts, &(&1.speaker == :user)) do
      nil -> nil
      part -> {snapshot.provider_generation, part.arrival_order}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp cancel_job(s) do
    if s.timer, do: Process.cancel_timer(elem(s.timer, 1))

    if s.job do
      Process.cancel_timer(s.job.timer)
      Task.shutdown(s.job.task, :brutal_kill)
    end

    %{s | timer: nil, job: nil}
  end

  defp sync_drops(%{outer_observer: %{credits: outer}} = s) do
    dropped = :atomics.get(s.credits, 2)
    if dropped > s.reported_drops, do: :atomics.add(outer, 2, dropped - s.reported_drops)
    %{s | reported_drops: dropped}
  end

  defp sync_drops(s), do: s

  defp audible?(<<sample::signed-little-16, _::binary>>) when sample > 128 or sample < -128,
    do: true

  defp audible?(<<_::signed-little-16, rest::binary>>), do: audible?(rest)
  defp audible?(_), do: false

  defp forward_audio(%{pid: pid, credits: credits}, direction, at, pcm) do
    if :atomics.add_get(credits, 1, 1) <= 256 do
      send(pid, {:parlora_audio, direction, at, pcm})
    else
      :atomics.sub(credits, 1, 1)
      :atomics.add(credits, 2, 1)
    end
  end

  defp forward_audio(_, _, _, _), do: :ok
end
