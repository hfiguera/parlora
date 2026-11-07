defmodule BookingDesk.CallGuard do
  alias BookingDesk.CallGuard.{Announcement, Classifier, NativeReply}
  @moduledoc "Per-call, fail-closed task gate, scope redirects and caller-conduct lifecycle."
  use GenServer, restart: :temporary
  alias Parlora.{AudioFormat, ContextUpdate, Error}

  # The fixed scope-close line, isolated from Ava's Phonic-1 software playout.
  @scope_close_path Path.expand("../../priv/announcements/scope-close.pcm", __DIR__)
  @external_resource @scope_close_path
  @scope_close_audio File.read!(@scope_close_path)
  @farewell_path Path.expand("../../priv/announcements/farewell.pcm", __DIR__)
  @external_resource @farewell_path
  @farewell_audio File.read!(@farewell_path)

  @doc false
  def scope_close_audio, do: @scope_close_audio

  @doc false
  def farewell_audio, do: @farewell_audio

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
       scope_reply: nil,
       scope_ready: nil,
       scope_held: false,
       scope_input_item: nil,
       scope_close_audio: Keyword.get(opts, :scope_close_audio),
       farewell_audio: Keyword.get(opts, :farewell_audio),
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
       scope_input_pending: false,
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
            start_emergency(%{s | key: key}, s.closing, snapshot)
          else
            s
          end

        {:reply, :blocked, s}

      s.scope_input_item != nil ->
        {:reply, :wait, s}

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
    s = observe_scope_reply(s, event)
    s = observe_scope_input(s, event)
    s = observe_emergency(s, event)

    s =
      case event do
        %{type: :transcript_delta, payload: %{speaker: :user}} ->
          %{s | serial: s.serial + 1}

        %{type: :transcript_delta, payload: %{speaker: :assistant}}
        when s.announcement != nil and not is_map_key(s.announcement, :local_duration_ms) ->
          %{s | announcement: Announcement.caption(s.announcement, event)}

        %{type: :provider_speech, payload: %{state: speech}} ->
          announcement =
            if speech == :speaking and s.speech != :speaking and s.announcement != nil and
                 not is_map_key(s.announcement, :local_duration_ms) and not s.emergency,
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
      if direction == :output and (s.announcement != nil or s.scope_reply != nil) and
           audible?(pcm) do
        %{
          s
          | announcement: s.announcement && Announcement.audible(s.announcement, now()),
            scope_reply: scope_audio(s.scope_reply, s.speech, at)
        }
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
      {:noreply, apply_result(s, result, snapshot)}
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

  def handle_info(
        {:emergency_prepared, token},
        %{announcement: %{token: token, phase: :preparing} = a} = s
      ),
      do: {:noreply, %{s | announcement: %{a | phase: :waiting}}}

  def handle_info(
        {:emergency_submitted, id, result},
        %{announcement: %{command_id: id, phase: :sending}} = s
      ),
      do: {:noreply, emergency_submission(s, result)}

  def handle_info({:close_input_sealed, :scope_close}, %{closing: :scope_close} = s) do
    s = %{s | scope_input_pending: false}

    case play_recorded_close(s, s.scope_close_audio) do
      {:ok, playing} -> {:noreply, playing}
      :unavailable when is_boolean(s.scope_ready) or s.scope_held -> {:noreply, s}
      :unavailable -> {:noreply, announce(s, :scope_close, true)}
    end
  end

  def handle_info({:close_input_sealed, :farewell}, %{closing: :farewell} = s) do
    case play_recorded_close(s, s.farewell_audio) do
      {:ok, playing} -> {:noreply, playing}
      :unavailable -> {:noreply, announce(s, :farewell, true)}
    end
  end

  def handle_info({:scope_tick, token}, %{scope_reply: %{token: token, key: key} = a} = s)
      when key == s.key or s.closing == :scope_close do
    elapsed = now() - a.requested_at
    last_output = max(a.last_voice, a.last_reply_at)
    quiet = now() - max(last_output, a.requested_at) >= s.quiet_ms
    ready = scope_ready?(s, a, quiet)

    cond do
      a.reason == :scope_close and s.scope_held and elapsed >= s.delivery_ms and not ready ->
        emit(s, :message_unconfirmed)
        finish_announcement(%{s | scope_reply: nil}, a, false)

      a.reason == :scope_close and not s.scope_input_pending and
          (ready or elapsed >= s.delivery_ms) ->
        {:noreply, announce(s, :scope_close, true, false)}

      a.reason == :scope_close and is_boolean(s.scope_ready) and s.scope_held and
        not s.scope_input_pending and is_binary(a.response_id) ->
        # The entire reply is still held. Discard it before telling the provider
        # it can stop waiting for playback and accept the goodbye.
        if s.transport.control(s.session, {:clear_output, :next}) == :ok do
          s.transport.control(s.session, {:output_discarded, a.response_id})
        end

        reschedule_scope(%{s | scope_reply: %{a | response_id: nil}}, token)

      a.reason == :scope_close ->
        reschedule_scope(s, token)

      scope_played?(s, a) and (scope_drained?(a) or (quiet and scope_idle?(s, a))) ->
        {:noreply, count_scope_reply(s)}

      ready ->
        {:noreply, announce(%{s | off_topic: s.off_topic + 1}, :scope_redirect, false, false)}

      elapsed >= s.delivery_ms ->
        emit(s, :message_unconfirmed)
        {:noreply, %{s | scope_reply: nil}}

      true ->
        reschedule_scope(s, token)
    end
  end

  def handle_info({:guard_tick, token}, %{announcement: %{token: token} = a} = s) do
    drained = a[:phase] != :preparing and playout_drained?(s, a)

    started = a[:sent_at] || a[:retry_started_at] || a.started
    confirmed_emergency_audio = s.emergency and a.caption and a.heard
    timed_out = now() - started >= s.delivery_ms and not confirmed_emergency_audio
    settled = s.job == nil and s.timer == nil
    hard_deadline = now() - started >= s.delivery_ms + s.debounce_ms + s.timeout_ms + 1_000

    cond do
      timed_out and retry_emergency_timeout?(a) ->
        # The local deadline can beat the provider's timeout event to the mailbox.
        Process.send_after(self(), {:guard_tick, token}, 100)
        {:noreply, retry_emergency(s, %{a | timeout_retried: true})}

      ((drained or timed_out) and settled) or hard_deadline ->
        emit(s, if(drained, do: :software_playout_quiet, else: :message_unconfirmed))
        finish_announcement(s, a, drained)

      true ->
        Process.send_after(self(), {:guard_tick, token}, 100)
        {:noreply, maybe_send_emergency(s, a)}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  def terminate(_, s) do
    sync_drops(s)
    cancel_job(s)
    :ok
  end

  defp observe_scope_reply(
         s,
         %{type: :provider_speech, payload: %{typed_ready: ready}}
       ),
       do: %{s | scope_ready: ready == true}

  defp observe_scope_reply(
         s,
         %{type: :provider_activity, payload: %{state: :in_progress}}
       ) do
    s = invalidate_scope_ready(s)
    %{s | scope_reply: s.scope_reply && %{s.scope_reply | generating: true}}
  end

  defp observe_scope_reply(
         s,
         %{type: :extension, payload: %{kind: :caller_speech, state: :started}}
       ),
       do: invalidate_scope_ready(s)

  defp observe_scope_reply(%{closing: :scope_close} = s, %{
         type: :transcript_delta,
         payload: %{speaker: :user}
       }),
       do: s

  defp observe_scope_reply(
         s,
         %{type: :transcript_delta, generation: generation, payload: %{speaker: :user}}
       ),
       do: %{s | scope_reply: new_scope_reply(generation)}

  defp observe_scope_reply(
         %{scope_reply: reply} = s,
         %{type: :transcript_delta, payload: %{speaker: :assistant}} = event
       )
       when reply != nil,
       do: %{s | scope_reply: Announcement.caption(%{reply | last_reply_at: now()}, event)}

  defp observe_scope_reply(
         %{scope_reply: reply, speech: :speaking} = s,
         %{type: :provider_speech, payload: %{state: :idle}}
       )
       when reply != nil,
       do: %{s | scope_reply: %{reply | speech_done: true, generated: true, last_reply_at: now()}}

  defp observe_scope_reply(
         %{scope_reply: reply, speech: speech} = s,
         %{type: :provider_speech, payload: %{state: :speaking}}
       )
       when reply != nil and speech != :speaking,
       do:
         invalidate_scope_ready(%{
           s
           | scope_reply: %{
               reply
               | speech_done: false,
                 generated: false,
                 drained_at: nil,
                 has_audio: false
             }
         })

  defp observe_scope_reply(s, %{type: :provider_speech, payload: %{state: :speaking}}),
    do: invalidate_scope_ready(s)

  defp observe_scope_reply(
         %{scope_reply: reply} = s,
         %{type: :provider_activity, payload: %{state: :idle} = payload}
       )
       when reply != nil do
    generated = reply.generated or payload[:status] == "completed"

    %{
      s
      | scope_reply: %{
          reply
          | generating: false,
            generated: generated,
            last_reply_at: now(),
            response_id: payload[:response_id]
        }
    }
  end

  defp observe_scope_reply(
         %{scope_reply: reply} = s,
         %{
           source: :channel,
           type: :audio_discontinuity,
           observed_at_us: at,
           payload: %{cause: :playback_starved}
         }
       )
       when reply != nil,
       do: %{s | scope_reply: %{reply | drained_at: div(at, 1_000)}}

  defp observe_scope_reply(%{closing: :scope_close} = s, %{type: :output_interrupted}),
    do: invalidate_scope_ready(s)

  defp observe_scope_reply(s, %{type: :output_interrupted, observed_at_us: at}) do
    s = invalidate_scope_ready(s)

    case s.scope_reply do
      %{reason: :scope_redirect, key: key, drained_at: drained} = reply
      when key == s.key and is_integer(at) and is_integer(drained) and div(at, 1_000) >= drained ->
        if scope_drained?(reply) and scope_played?(s, reply),
          do: count_scope_reply(s),
          else: %{s | scope_reply: nil}

      _other ->
        %{s | scope_reply: nil}
    end
  end

  defp observe_scope_reply(s, _event), do: s

  defp invalidate_scope_ready(%{scope_ready: nil} = s), do: s
  defp invalidate_scope_ready(s), do: %{s | scope_ready: false}

  defp scope_audio(nil, _speech, _at), do: nil

  defp scope_audio(reply, speech, at) do
    %{
      reply
      | last_voice: div(at, 1_000),
        has_audio: reply.has_audio or speech == :speaking or reply.text != ""
    }
  end

  defp scope_played?(s, reply),
    do: reply.has_audio and Announcement.scope_redirect?(reply, s.source.latest_user)

  defp scope_drained?(reply),
    do: reply.generated and is_integer(reply.drained_at) and reply.drained_at >= reply.last_voice

  defp scope_idle?(s, reply), do: s.speech != :speaking and not reply.generating

  defp count_scope_reply(s) do
    s = arm_scope_output(%{s | scope_reply: nil, off_topic: s.off_topic + 1})
    emit(s, :scope_redirect, %{delivery: :native})
    s
  end

  defp observe_scope_input(
         %{closing: nil, announcement: nil, off_topic: n} = s,
         %{type: :extension, payload: %{kind: :caller_speech, state: :started} = payload}
       )
       when n >= 2 do
    %{cancel_job(s) | scope_input_item: payload[:segment_id] || :next} |> arm_scope_output()
  end

  defp observe_scope_input(
         %{closing: nil, announcement: nil, off_topic: n} = s,
         %{type: :transcript_delta, payload: %{speaker: :user} = payload}
       )
       when n >= 2 do
    if s.scope_input_item in [nil, :next, payload[:segment_id]],
      do: arm_scope_output(%{s | scope_input_item: nil}),
      else: s
  end

  defp observe_scope_input(
         %{scope_input_item: pending} = s,
         %{type: :extension, payload: %{kind: :transcript_discarded, speaker: :user} = payload}
       )
       when pending != nil,
       do: abandon_scope_input(s, payload[:segment_id])

  defp observe_scope_input(
         %{scope_input_item: pending} = s,
         %{type: :extension, payload: %{kind: :caller_speech, state: :cancelled} = payload}
       )
       when pending != nil,
       do: abandon_scope_input(s, payload[:segment_id])

  defp observe_scope_input(s, _), do: s

  defp abandon_scope_input(%{scope_input_item: pending} = s, item)
       when pending == :next or pending == item,
       do: settle_scope_output(%{s | scope_input_item: nil}, :play)

  defp abandon_scope_input(s, _), do: s

  defp arm_scope_output(%{scope_held: false, off_topic: n} = s) when n >= 2,
    do: scope_output(s, :hold, true)

  defp arm_scope_output(s), do: s

  defp settle_scope_output(%{scope_held: true} = s, action), do: scope_output(s, action, false)
  defp settle_scope_output(s, _), do: s

  defp scope_output(s, action, held?) do
    case s.transport.control(s.session, {:hold_output, action}) do
      :ok ->
        %{s | scope_held: held?}

      _error ->
        emit(s, :scope_output_rejected)
        s
    end
  end

  defp reschedule_scope(s, token) do
    Process.send_after(self(), {:scope_tick, token}, 100)
    {:noreply, s}
  end

  defp scope_ready?(%{scope_ready: ready} = s, _reply, quiet) when is_boolean(ready),
    do: ready and (s.scope_held or quiet)

  # A held third reply can be discarded once generation ends. An audible
  # redirect needs time to finish playing before the guard considers a fallback.
  defp scope_ready?(s, %{reason: :scope_close} = reply, quiet),
    do: scope_idle?(s, reply) and (reply.speech_done or quiet)

  defp scope_ready?(s, reply, quiet), do: quiet and scope_idle?(s, reply)

  defp new_scope_reply(generation) do
    expected = [
      message(:scope_redirect),
      "I can help with clinic scheduling. What appointment help do you need?"
    ]

    started = now()

    :scope_redirect
    |> Announcement.new(expected, generation, started)
    |> Map.merge(%{
      generated: false,
      generating: false,
      has_audio: false,
      drained_at: nil,
      response_id: nil,
      last_reply_at: started,
      speech_done: false
    })
  end

  defp await_scope_reply(%{key: {generation, _}} = s, reason) do
    reply =
      case s.scope_reply do
        %{generation: ^generation} = reply -> reply
        _ -> new_scope_reply(generation)
      end

    Process.send_after(self(), {:scope_tick, reply.token}, 100)
    %{s | scope_reply: Map.merge(reply, %{key: s.key, requested_at: now(), reason: reason})}
  end

  defp schedule_check(s, snapshot, key) do
    s = %{cancel_job(s) | native_reply: NativeReply.check(s.native_reply, key)}
    dialogue = BookingDesk.Dialogue.build(snapshot.transcripts, limit: 6)

    source = %{
      dialogue: dialogue,
      latest_user: List.last(Enum.filter(dialogue, &(&1.speaker == :user))).text
    }

    s = maybe_hold_farewell(s, snapshot, source.latest_user)

    if byte_size(JSON.encode!(source)) > 6_000 do
      s = %{s | key: key, verdict: :blocked}
      {:reply, :blocked, announce(s, :unavailable, true)}
    else
      token = make_ref()
      timer = Process.send_after(self(), {:classify, token}, s.debounce_ms)
      {:reply, :wait, %{s | key: key, source: source, verdict: nil, timer: {token, timer}}}
    end
  end

  defp playout_drained?(s, %{local_duration_ms: duration, first_voice: first} = a) do
    at = now()
    first != nil and at >= first + duration and at - a.last_voice >= s.quiet_ms
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
    s = if drained and a.reason == :scope_redirect, do: arm_scope_output(s), else: s
    {:noreply, %{s | announcement: nil}}
  end

  defp undo_warning(s, %{reason: :abuse_warning}), do: %{s | abuse: max(0, s.abuse - 1)}
  defp undo_warning(s, %{reason: :scope_redirect}), do: %{s | off_topic: max(0, s.off_topic - 1)}
  defp undo_warning(s, _), do: s

  defp gate(%{closing: reason}) when reason != nil, do: :blocked
  defp gate(%{verdict: :allowed}), do: :allow
  defp gate(%{verdict: nil}), do: :wait
  defp gate(_), do: :blocked

  defp apply_result(s, {:ok, kind}, snapshot) when kind in [:emergency, :possible_emergency],
    do: start_emergency(s, kind, snapshot)

  defp apply_result(%{closing: reason} = s, _, _) when reason != nil, do: s

  defp apply_result(s, {:ok, :allowed}, snapshot) do
    if farewell?(s, snapshot, s.source.latest_user) do
      seal_input(%{s | verdict: :blocked}, :farewell)
    else
      emit(s, :allowed)
      settle_scope_output(%{s | verdict: :allowed, scope_reply: nil}, :play)
    end
  end

  defp apply_result(s, {:ok, :abuse}, _) do
    s = %{s | verdict: :blocked}

    if s.announcement != nil and s.announcement.reason == :abuse_warning do
      s
    else
      s = %{s | abuse: s.abuse + 1}
      announce(s, if(s.abuse == 1, do: :abuse_warning, else: :abuse_close), s.abuse > 1)
    end
  end

  defp apply_result(s, {:ok, :off_topic}, _) do
    s = %{s | verdict: :blocked}

    cond do
      s.announcement != nil ->
        s

      s.off_topic >= 2 ->
        close_for_scope(s)

      native_reply?(s) ->
        coalesce_boundary(s, :off_topic)

      s.scope_reply != nil or is_boolean(s.scope_ready) ->
        await_scope_reply(s, :scope_redirect)

      true ->
        announce(%{s | off_topic: s.off_topic + 1}, :scope_redirect, false)
    end
  end

  defp apply_result(s, {:ok, :medical_question}, _),
    do: announce(%{s | verdict: :blocked}, :medical_redirect, false)

  defp apply_result(s, {:error, :uncertain}, _) do
    s = %{s | verdict: :blocked}

    if native_reply?(s),
      do: coalesce_boundary(s, :uncertain),
      else: announce(s, :clarify_scope, false)
  end

  defp apply_result(s, _, _), do: announce(%{s | verdict: :blocked}, :unavailable, true)

  defp start_emergency(s, reason, snapshot) do
    if match?(%{local_duration_ms: _}, s.announcement) do
      s.transport.control(s.session, {:clear_output, :next})
    end

    s = undo_warning(s, s.announcement)
    s = settle_scope_output(s, :play)
    emit(s, reason)

    generation = elem(s.key, 0)

    announcement =
      Announcement.new(reason, emergency_messages(reason), generation, now())
      |> seed_emergency_caption(snapshot.transcripts)
      |> Map.merge(%{
        phase: :preparing,
        command_id: nil,
        response_id: nil,
        sent_at: nil,
        retry_started_at: nil,
        timeout_retried: false,
        instruction_sent: false
      })

    owner = self()

    async(s, fn ->
      try do
        mute_input(s, s.session, s.transport)
      after
        send(owner, {:emergency_prepared, announcement.token})
      end
    end)

    Process.send_after(self(), {:guard_tick, announcement.token}, 100)

    %{
      s
      | emergency: true,
        verdict: :blocked,
        closing: reason,
        announcement: announcement,
        scope_reply: nil
    }
  end

  defp seed_emergency_caption(announcement, transcripts) do
    transcripts
    |> Enum.take_while(&(&1.speaker == :assistant))
    |> Enum.reverse()
    |> Enum.reduce(announcement, fn part, current ->
      Announcement.caption(current, %{generation: part[:provider_generation], payload: part})
    end)
  end

  defp maybe_send_emergency(%{speech: speech} = s, %{phase: :waiting} = a)
       when speech != :speaking do
    if now() - a.last_voice >= s.quiet_ms do
      # The provider may have started a safe reply before the application classified the turn.
      # Preserve its audio and only offer the fallback after the software playout is quiet.
      owner = self()
      instruction = emergency_instruction()
      update = announcement_update(a.reason, a.generation, instruction)

      async(s, fn ->
        if not a.instruction_sent do
          set_emergency_instruction(s, s.session, s.transport, update, instruction)
        end

        result = s.transport.append_context(s.session, update)
        send(owner, {:emergency_submitted, update.id, result})
      end)

      a = Announcement.reset(a)

      %{
        s
        | announcement: %{
            a
            | phase: :sending,
              command_id: update.id,
              sent_at: now(),
              instruction_sent: true
          }
      }
    else
      s
    end
  end

  defp maybe_send_emergency(s, _), do: s

  defp observe_emergency(
         %{emergency: true, announcement: %{command_id: id, phase: phase} = a} = s,
         %{type: :context_acknowledged, command_id: id, payload: %{response_id: response}}
       )
       when is_binary(id) and is_binary(response) and phase in [:sending, :submitted],
       do: %{s | announcement: %{a | response_id: response}}

  defp observe_emergency(
         %{emergency: true, announcement: %{response_id: response} = a} = s,
         %{
           type: :provider_activity,
           payload: %{
             state: :idle,
             response_id: response,
             status: "failed",
             reason: "response_timeout"
           }
         }
       )
       when is_binary(response) do
    if retry_emergency_timeout?(a) and not (a.caption and a.heard),
      do: retry_emergency(s, %{a | timeout_retried: true}),
      else: s
  end

  defp observe_emergency(
         %{announcement: %{command_id: id, phase: phase}} = s,
         %{type: :context_rejected, command_id: id, payload: payload}
       )
       when is_binary(id) and phase in [:sending, :submitted],
       do: emergency_submission(s, {:error, payload[:error]})

  defp observe_emergency(
         %{emergency: true, announcement: %{phase: phase} = a} = s,
         %{type: :output_interrupted}
       )
       when phase in [:sending, :submitted],
       do: retry_emergency(s, a)

  defp observe_emergency(%{emergency: true, announcement: a} = s, %{type: :output_interrupted})
       when a != nil,
       do: %{s | announcement: Announcement.reset(a)}

  defp observe_emergency(s, _), do: s

  defp retry_emergency_timeout?(%{phase: phase, response_id: id, timeout_retried: false}),
    do: is_binary(id) and phase in [:sending, :submitted]

  defp retry_emergency_timeout?(_announcement), do: false

  defp retry_emergency(s, a) do
    at = now()
    a = Announcement.reset(a)

    %{
      s
      | announcement: %{
          a
          | phase: :waiting,
            command_id: nil,
            response_id: nil,
            sent_at: nil,
            retry_started_at: at,
            last_voice: at
        }
    }
  end

  defp emergency_submission(%{announcement: a} = s, :ok),
    do: %{s | announcement: %{a | phase: :submitted}}

  defp emergency_submission(%{announcement: a} = s, {:error, %Error{code: :backpressure}}),
    do: %{
      s
      | announcement: %{a | phase: :waiting, command_id: nil, response_id: nil, sent_at: nil}
    }

  defp emergency_submission(%{announcement: a} = s, _error) do
    emit(s, :message_rejected)
    %{s | announcement: %{a | phase: :failed}}
  end

  defp emergency_messages(:possible_emergency),
    do: [
      message(:possible_emergency),
      message(:emergency),
      "Please " <> possible_emergency_guidance()
    ]

  defp emergency_messages(:emergency), do: [message(:emergency)]

  defp close_for_scope(s) do
    s = seal_input(%{s | scope_input_pending: true}, :scope_close)
    if is_boolean(s.scope_ready) or s.scope_held, do: await_scope_reply(s, :scope_close), else: s
  end

  defp maybe_hold_farewell(%{scope_held: false} = s, snapshot, text) do
    if farewell?(s, snapshot, text), do: scope_output(s, :hold, true), else: s
  end

  defp maybe_hold_farewell(s, _snapshot, _text), do: s

  defp farewell?(%{closing: nil, farewell_audio: audio}, snapshot, text) when is_binary(audio) do
    Regex.match?(
      ~r/\A\s*(?:(?:thank you|thanks)[.,!\s]+)?(?:bye(?:[ -]bye)?|goodbye)[.!\s]*\z/iu,
      text
    ) and
      match?(%{status: "scheduled"}, BookingDesk.ReminderPolicy.state(snapshot))
  end

  defp farewell?(_s, _snapshot, _text), do: false

  defp seal_input(s, reason) do
    owner = self()

    async(s, fn ->
      try do
        mute_input(s, s.session, s.transport)
      after
        send(owner, {:close_input_sealed, reason})
      end
    end)

    %{s | closing: reason}
  end

  defp play_recorded_close(%{scope_held: true, closing: reason} = s, audio)
       when is_binary(audio) do
    format = %AudioFormat{}

    case s.transport.control(s.session, {:replace_output, format, audio}) do
      :ok ->
        duration_ms = div(AudioFormat.duration_us(format, byte_size(audio)) + 999, 1_000)

        announcement =
          Announcement.new(reason, message(reason), elem(s.key, 0), now())
          |> Map.merge(%{local_duration_ms: duration_ms, first_voice: nil, caption: true})

        emit(s, reason, %{delivery: :recorded})
        Process.send_after(self(), {:guard_tick, announcement.token}, 100)
        {:ok, %{s | scope_held: false, scope_reply: nil, announcement: announcement}}

      _error ->
        :unavailable
    end
  end

  defp play_recorded_close(_, _), do: :unavailable

  defp native_reply?(s),
    do: s.native_result_replies and NativeReply.active?(s.native_reply, s.key)

  defp coalesce_boundary(s, reason) do
    s = settle_scope_output(%{s | scope_reply: nil}, :play)
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
    do: "If this may be a medical emergency, please " <> possible_emergency_guidance()

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

  def message(:farewell), do: "Thanks for calling. Take care!"

  def message(:medical_redirect),
    do:
      "I cannot provide medical advice. Please speak with a qualified medical professional. I can help you arrange an appointment."

  def message(:clarify_scope),
    do:
      "I can help with clinic scheduling and registration. Could you tell me what you need help arranging?"

  def message(:unavailable),
    do:
      "I am unable to handle this request safely right now. If this is a medical emergency, call 911. Please try again later. Goodbye."

  defp possible_emergency_guidance do
    "hang up and call 911 now, or your local emergency number outside the United States. I cannot contact emergency services for you. Goodbye."
  end

  defp announce(s, reason, close?, clear? \\ true) do
    # Replacing an unfinished lower-priority message does not make it a delivered warning.
    s = undo_warning(s, s.announcement)
    s = settle_scope_output(s, :discard)

    emit(s, reason)
    started = now()
    generation = elem(s.key, 0)

    update = announcement_update(reason, generation, "")
    async(s, fn -> deliver_announcement(s, update, clear?) end)

    announcement = Announcement.new(reason, message(reason), generation, started)
    Process.send_after(self(), {:guard_tick, announcement.token}, 100)

    %{
      s
      | closing: if(close?, do: reason),
        announcement: announcement,
        scope_reply: nil
    }
  end

  defp announcement_update(reason, generation, instruction) do
    %ContextUpdate{
      id: "call-guard-#{System.unique_integer([:positive])}",
      kind: :speakable,
      provider_generation: generation,
      content:
        instruction <>
          "Application call-boundary decision. Do not continue the previous topic or claim any new backend result. Say this concise message without adding unrelated conversation: " <>
          message(reason)
    }
  end

  defp emergency_instruction do
    "EMERGENCY CLOSING MODE. This is a clinic scheduling call, not a 911 connection. " <>
      "All new scheduling and patient lookups are blocked for the rest of this call. " <>
      "Do not collect name/DOB or insurance, offer appointments, or say you are pulling a file, checking records or booking. " <>
      "No emergency services have been called or connected. Give the emergency instruction, end with Goodbye, " <>
      "and do not resume ordinary conversation while the application closes the line. "
  end

  defp deliver_announcement(
         %{session: session, transport: transport} = s,
         update,
         clear?
       ) do
    current = transport.snapshot(session)

    if s.closing == :scope_close or key(current) == s.key do
      update = %{update | provider_generation: current.provider_generation}
      if clear?, do: transport.control(session, {:clear_output, :next})

      case transport.append_context(session, update) do
        :ok -> :ok
        _ -> emit(s, :message_rejected)
      end
    else
      emit(s, :stale_boundary_action)
    end
  end

  defp mute_input(s, session, transport) do
    if transport.control(session, {:input_muted, true}) != :ok, do: emit(s, :input_mute_rejected)
  end

  defp set_emergency_instruction(%{instruction_updates: false}, _, _, _, _), do: :ok

  defp set_emergency_instruction(s, session, transport, update, instruction) do
    update = %{update | id: update.id <> "-mode", kind: :instruction, content: instruction}
    if transport.append_context(session, update) != :ok, do: emit(s, :instruction_rejected)
  end

  defp async(_s, function), do: Task.Supervisor.start_child(BookingDesk.GuardTasks, function)

  defp emit(s, outcome, metadata \\ %{}) do
    metadata = Map.merge(metadata, %{outcome: outcome, session_id: s.session_id})

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
