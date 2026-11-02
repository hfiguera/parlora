defmodule BookingDesk.Run do
  @moduledoc "Bounded live scenarios driven by task and speech milestones, never injected transcripts."
  alias BookingDesk.{Recorder, ReplayChannel}
  alias Parlora.Event
  alias Parlora.Providers.Phonic

  def run(directory, clips, opts \\ []) do
    if Keyword.get(opts, :observability, false) do
      {:ok, _} = Application.ensure_all_started(:parlora_observer)
    end

    unless Process.whereis(BookingDesk.TypeSafe),
      do: raise("TYPESAFE_API_KEY is required for BookingDesk")

    mode = Keyword.get(opts, :mode, :replay)

    if mode == :microphone and opts[:ambience],
      do: raise("Ambience is supported only by the replay caller")

    ambience = BookingDesk.Ambience.prepare!(opts[:ambience], directory)
    {:ok, recorder} = Recorder.start_link(directory: directory)
    observer = Recorder.observer(recorder)

    channel =
      if mode == :microphone,
        do: {Parlora.Channels.LocalAudio, audio_observer: observer},
        else:
          {ReplayChannel,
           owner: self(), audio_observer: observer, recorder: recorder, ambience: ambience}

    native_conversation = Keyword.get(opts, :phonic_native_conversation, true)

    provider_options =
      BookingDesk.PhonicSettings.options(
        System.get_env("PARLORA_PROVIDER", "openai"),
        native_conversation
      )

    {:ok, session} =
      BookingDesk.start(channel, phonic_native_conversation: native_conversation)

    {:ok, readback} = BookingDesk.Readback.start_link()
    Process.send_after(self(), :deadline, 210_000)

    start_microphone(mode)

    Process.send_after(self(), :poll, 200)

    s = %{
      session: session,
      recorder: recorder,
      readback: readback,
      readback_revision: 0,
      channel: nil,
      clips: clips,
      mode: mode,
      provider_options: Map.new(provider_options),
      provider_defaults: provider_defaults(),
      any_doctor: Keyword.get(opts, :any_doctor, false),
      clinician_replies: MapSet.new(),
      ambience: ambience != nil,
      stage: :starting,
      greeting_audio: false,
      greeting_completed: false,
      text: "",
      speech: :unknown,
      source_sha256:
        Map.new(Path.wildcard("lib/**/*.ex"), fn path ->
          {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
        end),
      library_source_sha256:
        Map.new(Path.wildcard("../../lib/**/*.ex"), fn path ->
          {Path.relative_to(path, "../.."),
           :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
        end),
      submitted: [],
      prep_during_work: false,
      announced_confirmation: false,
      confirmation_readback: false,
      booking_request: nil,
      expected_confirmation: nil,
      booking_result_at: nil,
      insurance: nil,
      reminder: nil,
      identity_request: nil,
      stale: 0,
      failed: [],
      stage_at: System.monotonic_time(:millisecond),
      last_audio_at: System.monotonic_time(:millisecond),
      stage_due: 0
    }

    try do
      loop(s)
    after
      if Process.alive?(readback), do: GenServer.stop(readback)
      if Process.alive?(session), do: Parlora.close(session)
    end
  end

  defp provider_defaults do
    if System.get_env("PARLORA_PROVIDER", "openai") == "phonic",
      do: Map.new(Phonic.default_options()),
      else: %{}
  end

  defp start_microphone(:microphone) do
    IO.puts("Demo records: Jamie Rivera — March 12, 1990; Alex Morgan — July 24, 1985.")
    owner = self()

    spawn(fn ->
      IO.gets("Recording enabled. Use headphones. Press Enter to stop.\n")
      send(owner, :stop)
    end)
  end

  defp start_microphone(_), do: :ok

  defp loop(s) do
    receive do
      {:playout_active, at} ->
        loop(%{
          s
          | last_audio_at: at,
            readback_revision: s.readback_revision + 1,
            greeting_audio: s.greeting_audio or s.stage == :greeting
        })

      {:channel, pid} ->
        loop(%{s | channel: pid})

      {:parlora_event, %Event{} = event} ->
        Recorder.event(s.recorder, event)
        next = event(s, event)
        if next.stage == :done, do: finish(next, :completed), else: loop(next)

      {:play, id} ->
        loop(play(s, id))

      :poll ->
        Process.send_after(self(), :poll, 200)
        next = advance(s)
        if next.stage == :done, do: finish(next, :completed), else: loop(next)

      :stop ->
        finish(s, :stopped)

      :deadline ->
        finish(s, :timeout)

      _ ->
        loop(s)
    end
  end

  defp event(%{stage: :starting} = s, %{source: :session, type: :ready}) do
    IO.puts("Ready: #{System.get_env("PARLORA_PROVIDER", "openai")} (recording fictional data)")
    update = BookingDesk.Greeting.update(Parlora.snapshot(s.session).provider_generation)
    Recorder.mark(s.recorder, "assistant:greeting_requested", %{context_update_id: update.id})

    case Parlora.append_context(s.session, update) do
      :ok ->
        %{
          s
          | stage: if(s.mode == :replay, do: :greeting, else: :microphone),
            stage_at: System.monotonic_time(:millisecond),
            text: ""
        }

      {:error, _} ->
        %{s | stage: :done, failed: [:greeting | s.failed]}
    end
  end

  defp event(s, %{source: :session, type: :task_submitted, payload: %{request: r}}) do
    IO.puts("Task: #{r.input.operation} #{Map.get(r.input, :date, "")}")

    s = %{
      s
      | submitted: [
          Map.merge(r.input, %{request_id: r.id, task_id: r.task_id, revision: r.task_revision})
          | s.submitted
        ]
    }

    cond do
      s.stage in [:insurance, :clinician] && r.input.operation == "availability" &&
          r.input.date == "2026-11-04" ->
        Process.send_after(self(), {:play, "preparation"}, 500)
        s

      s.stage == :confirm && r.input.operation == "confirm" ->
        Process.send_after(self(), {:play, "progress"}, 500)
        %{s | booking_request: r.id}

      true ->
        s
    end
  end

  defp event(s, %{
         source: :session,
         type: :result_delivery,
         request_id: id,
         payload: %{stage: stage}
       })
       when stage in [:accepted, :unconfirmed] do
    if id == s.booking_request && s.booking_result_at == nil do
      %{s | booking_result_at: System.monotonic_time(:millisecond), text: ""}
    else
      s
    end
  end

  defp event(s, %{
         source: :backend,
         type: :request_completed,
         request_id: id,
         payload: %{facts: facts}
       }) do
    insurance = fact(facts, :insurance)

    s =
      if insurance && s.insurance == nil do
        %{
          s
          | insurance: %{
              carrier: fact(insurance, :carrier),
              revision: fact(insurance, :revision)
            },
            identity_request: id
        }
      else
        s
      end

    reminder = fact(facts, :reminder)
    s = if reminder, do: %{s | reminder: reminder}, else: s

    if id == s.booking_request do
      %{
        s
        | expected_confirmation: fact(facts, :confirmation)
      }
    else
      s
    end
  end

  defp event(s, %{type: :stale_result}), do: %{s | stale: s.stale + 1}

  defp event(s, %{type: :transcript_delta, payload: %{speaker: :assistant, delta: text}}) do
    combined = s.text <> text

    pending =
      s.stage == :preparation and
        Parlora.snapshot(s.session).tasks
        |> Enum.any?(fn {_, task} ->
          task.status == :submitted and task.input.operation == "availability" and
            task.input.date == "2026-11-04"
        end)

    %{
      s
      | text: combined,
        readback_revision: s.readback_revision + 1,
        prep_during_work:
          s.prep_during_work or
            (pending and Regex.match?(~r/bring|insurance|photo|early/i, combined)),
        announced_confirmation:
          s.announced_confirmation or
            (s.booking_result_at != nil and booked?() and
               Regex.match?(~r/confirmation|B[ .-]?D/i, combined))
    }
  end

  defp event(s, %{type: :transcript_delta, payload: %{speaker: :user}}),
    do: %{s | readback_revision: s.readback_revision + 1}

  defp event(s, %{source: :provider, type: :provider_speech, payload: %{state: speech}}),
    do: %{
      s
      | speech: speech,
        readback_revision: s.readback_revision + if(s.speech == speech, do: 0, else: 1)
    }

  defp event(s, %{type: :failed, source: source}),
    do: %{s | failed: [source | s.failed], stage: :done}

  defp event(s, %{source: :session, type: :closed}), do: %{s | stage: :done}
  defp event(s, _), do: s
  defp fact(facts, key), do: Map.get(facts, key) || Map.get(facts, Atom.to_string(key))

  @doc false
  def advance(%{mode: :microphone} = s), do: s

  def advance(s) do
    age = System.monotonic_time(:millisecond) - s.stage_at

    settled =
      age >= s.stage_due && s.speech != :speaking && age > 2_000 &&
        System.monotonic_time(:millisecond) - s.last_audio_at > 1_000

    advance_stage(s, settled, age)
  end

  defp advance_stage(%{stage: :greeting} = s, _settled, _age) do
    advance_greeting(s)
  end

  defp advance_stage(%{stage: :search} = s, settled, _age) do
    if settled && BookingDesk.Identity.requested?(s.text) do
      play(s, "identity", %{
        transcript_sha256: :crypto.hash(:sha256, s.text) |> Base.encode16(case: :lower)
      })
    else
      s
    end
  end

  defp advance_stage(%{stage: :identity} = s, settled, _age) do
    if s.insurance != nil && settled &&
         BookingDesk.Insurance.requested?(s.text, s.insurance.carrier) &&
         s.channel != nil && ReplayChannel.output_drained?(s.channel) do
      play(s, "insurance", %{
        transcript_sha256: :crypto.hash(:sha256, s.text) |> Base.encode16(case: :lower),
        carrier: s.insurance.carrier,
        insurance_revision: s.insurance.revision,
        lookup_request: s.identity_request
      })
    else
      s
    end
  end

  defp advance_stage(%{stage: :preparation} = s, settled, _age) do
    if settled &&
         Regex.match?(~r/bring|insurance|identification|photo|early/i, s.text) do
      play(s, "correction")
    else
      s
    end
  end

  defp advance_stage(%{stage: stage} = s, settled, _age) when stage in [:insurance, :clinician],
    do: advance_clinician(s, settled)

  defp advance_stage(%{stage: :correction} = s, settled, _age) do
    if settled &&
         Regex.match?(~r/10.?15|ten.?fifteen|two|2.?00|available|openings/i, s.text) do
      play(s, "choose")
    else
      s
    end
  end

  defp advance_stage(%{stage: :choose} = s, settled, _age) do
    advance_readback(s, settled)
  end

  defp advance_stage(%{stage: stage} = s, settled, _age) when stage in [:confirm, :progress] do
    if settled && confirmation_ready?(s) && booked?() &&
         s.booking_result_at != nil && s.last_audio_at > s.booking_result_at &&
         reminder_offer?(s.text) do
      play(s, "reminder", %{booking_request: s.booking_request, output_drained: true})
    else
      s
    end
  end

  defp advance_stage(%{stage: :reminder} = s, settled, _age) do
    if settled && s.reminder != nil &&
         Map.get(s.reminder, "status", Map.get(s.reminder, :status)) == "verify_existing" &&
         reminder_readback_verified?(s.session) &&
         s.channel != nil && ReplayChannel.output_drained?(s.channel) do
      play(s, "phone_confirm", %{
        last_four: Map.get(s.reminder, "last_four", Map.get(s.reminder, :last_four)),
        output_drained: true
      })
    else
      s
    end
  end

  defp advance_stage(%{stage: :phone_confirm} = s, settled, _age) do
    if settled && s.reminder != nil &&
         Map.get(s.reminder, "status", Map.get(s.reminder, :status)) == "scheduled" &&
         Regex.match?(~r/reminder|text/i, s.text) && Regex.match?(~r/scheduled|set|send/i, s.text) &&
         s.channel != nil && ReplayChannel.output_drained?(s.channel) do
      play(s, "goodbye")
    else
      s
    end
  end

  defp advance_stage(%{stage: :goodbye} = s, settled, age) do
    if settled && age > s.stage_due + 3_000 do
      %{s | stage: :done}
    else
      s
    end
  end

  defp advance_stage(s, _settled, _age), do: s

  defp advance_clinician(s, true) do
    answered = Map.get(s, :clinician_replies, MapSet.new())

    with true <- MapSet.size(answered) < 2,
         true <- String.contains?(s.text, "?"),
         scope when is_map(scope) <- clinician_question(s),
         false <- MapSet.member?(answered, scope.question_id),
         true <- s.channel != nil and ReplayChannel.output_drained?(s.channel) do
      next = play(s, "clinician", scope)

      if next.readback_revision > s.readback_revision,
        do: Map.put(next, :clinician_replies, MapSet.put(answered, scope.question_id)),
        else: next
    else
      _ -> s
    end
  end

  defp advance_clinician(s, _), do: s

  defp clinician_question(%{session: session, identity_request: lookup}) when is_pid(session) do
    snapshot = Parlora.snapshot(session)

    BookingDesk.ClinicianClarification.pending(
      snapshot,
      lookup,
      BookingDesk.Policy.insurance(snapshot),
      "2026-11-04"
    )
  end

  defp clinician_question(_), do: nil

  defp reminder_readback_verified?(session) do
    snapshot = Parlora.snapshot(session)

    BookingDesk.ReminderReadback.verified?(
      snapshot,
      BookingDesk.ReminderPolicy.state(snapshot)
    )
  end

  @doc false
  def reminder_offer?(text),
    do:
      Regex.match?(~r/text|SMS/i, text) && Regex.match?(~r/remind/i, text) &&
        String.contains?(text, "?")

  def confirmation_ready?(s) do
    BookingDesk.Confirmation.complete?(s.text, s.expected_confirmation) and
      s.channel != nil and ReplayChannel.output_drained?(s.channel)
  end

  defp play(s, id, milestone \\ nil)
  defp play(%{stage: :greeting} = s, "search", nil), do: s
  defp play(s, "identity", nil), do: s

  defp play(s, id, milestone) do
    clip = caller_clip(s, id)

    pcm = File.read!(Path.join(s.clips, clip <> ".pcm"))

    case ReplayChannel.play(s.channel, pcm, id) do
      :ok ->
        BookingDesk.Readback.check(s.readback, %{settled: false})

        mark_milestone(s, id, milestone)

        Recorder.mark(s.recorder, "caller:" <> id, %{duration_ms: byte_size(pcm) / 48, clip: clip})

        IO.puts("Caller: #{id}")
        # IDs are a fixed application allowlist, never atoms created from provider text.
        played_state(s, id, pcm)

      {:error, :busy} ->
        retry_play(s, id)
    end
  end

  defp caller_clip(%{any_doctor: true}, "search"), do: "search_any"
  defp caller_clip(%{any_doctor: true}, "clinician"), do: "search_any"
  defp caller_clip(_, "clinician"), do: "search"
  defp caller_clip(%{any_doctor: true}, "choose"), do: "choose_patel"
  defp caller_clip(_, id), do: id

  defp mark_milestone(s, "identity", milestone),
    do: Recorder.mark(s.recorder, "assistant:identity_requested", milestone)

  defp mark_milestone(s, "insurance", milestone),
    do: Recorder.mark(s.recorder, "assistant:insurance_requested", milestone)

  defp mark_milestone(s, id, milestone) when id in ["clinician", "reminder", "phone_confirm"],
    do: Recorder.mark(s.recorder, "assistant:" <> id <> "_requested", milestone)

  defp mark_milestone(s, "confirm", milestone),
    do: Recorder.mark(s.recorder, "assistant:proposal_readback", milestone)

  defp mark_milestone(%{stage: :greeting} = s, "search", milestone),
    do: Recorder.mark(s.recorder, "assistant:greeting_completed", milestone)

  defp mark_milestone(_, _, _), do: :ok

  defp played_state(s, id, pcm) do
    stage =
      %{
        "search" => :search,
        "identity" => :identity,
        "insurance" => :insurance,
        "clinician" => :clinician,
        "preparation" => :preparation,
        "correction" => :correction,
        "choose" => :choose,
        "confirm" => :confirm,
        "progress" => :progress,
        "reminder" => :reminder,
        "phone_confirm" => :phone_confirm,
        "goodbye" => :goodbye
      }[id]

    %{
      s
      | stage: stage,
        text: "",
        readback_revision: s.readback_revision + 1,
        confirmation_readback: s.confirmation_readback or id == "confirm",
        greeting_completed: s.greeting_completed or (id == "search" and s.stage == :greeting),
        stage_at: System.monotonic_time(:millisecond),
        stage_due: trunc(byte_size(pcm) / 48) + 1_500
    }
  end

  defp retry_play(s, id) do
    # Approval retries must pass the fresh proposal/transcript gate again.
    if id not in ["confirm", "identity", "insurance", "clinician", "reminder", "phone_confirm"] and
         not (id == "search" and s.stage == :greeting),
       do: Process.send_after(self(), {:play, id}, 100)

    s
  end

  defp advance_greeting(s) do
    observation = %{
      text: s.text,
      speech: s.speech,
      heard_audio: s.greeting_audio,
      output_drained: s.channel != nil && ReplayChannel.output_drained?(s.channel),
      quiet_ms: System.monotonic_time(:millisecond) - s.last_audio_at
    }

    if BookingDesk.Greeting.ready?(observation) do
      play(s, "search", Map.take(observation, [:output_drained, :quiet_ms]))
    else
      s
    end
  end

  defp advance_readback(s, settled) do
    snapshot = Parlora.snapshot(s.session)

    input = %{
      settled: settled,
      text: s.text,
      revision: s.readback_revision,
      generation: snapshot.provider_generation,
      proposal: BookingDesk.Readback.current_proposal(snapshot)
    }

    case BookingDesk.Readback.check(s.readback, input) do
      {:ready, evidence} ->
        play(s, "confirm", evidence)

      :waiting ->
        s
    end
  end

  defp booked?,
    do:
      Enum.any?(BookingDesk.Store.snapshot(), fn [id, _, _, status, _] ->
        id != "appt_existing" && status == "booked"
      end)

  defp finish(s, outcome) do
    ambience =
      if s.ambience and Process.alive?(s.channel), do: ReplayChannel.ambience_info(s.channel)

    if Process.alive?(s.session), do: Parlora.close(s.session, :finish)
    Process.sleep(500)
    flush(s.recorder)
    appointments = BookingDesk.Store.snapshot()
    submissions = Enum.reverse(s.submitted)

    checks = workflow_checks(s, outcome, appointments, submissions)

    checks =
      if s.mode == :replay,
        do: Map.put(checks, :assistant_greeted_first, s.greeting_completed),
        else: checks

    assessment =
      if s.mode == :microphone do
        BookingDesk.RunReport.microphone(
          submissions,
          appointments,
          BookingDesk.Store.reminder_jobs(),
          s.failed
        )
      else
        %{}
      end

    report =
      Recorder.finish(
        s.recorder,
        Map.merge(
          %{
            provider: System.get_env("PARLORA_PROVIDER", "openai"),
            model: model(),
            assistant_voice:
              BookingDesk.assistant_voice(System.get_env("PARLORA_PROVIDER", "openai")),
            jev_model: Application.fetch_env!(:booking_desk, :jev_model),
            opening: %{
              kind: "assistant_first",
              quiet_ms: 1_000,
              observation:
                "nonquiet software playout, assistant captions and drained output queue"
            },
            readback_evaluator: %{
              kind: "jev",
              model: Application.fetch_env!(:booking_desk, :jev_model),
              timeout_ms: 2_000,
              max_evaluations: 8
            },
            identity_extractor: %{
              kind: "structured_llm",
              library: "req_llm",
              model: Application.fetch_env!(:booking_desk, :identity_model),
              timeout_ms: 4_000,
              evidence:
                "caller excerpts and deterministic name/date validation; exact database match"
            },
            mode: s.mode,
            provider_options: s.provider_options,
            provider_defaults: s.provider_defaults,
            scenario: "booking-correction",
            booking_flow: %{
              version: 4,
              reminder: "optional_sms_24h_simulated_existing_cell_confirmation",
              patient_lookup: "full_name_and_dob",
              insurance: "confirm_stored_carrier_before_availability",
              requested_clinician: if(s.any_doctor, do: "any", else: "lee"),
              expected_clinician: if(s.any_doctor, do: "patel", else: "lee")
            },
            outcome: outcome,
            passed: Enum.all?(checks, fn {_, v} -> v end),
            checks: checks,
            delays_ms: Application.fetch_env!(:booking_desk, :delays),
            timezone: "America/Denver",
            fictional_today: "2026-11-02",
            appointments: appointments,
            reminder_jobs: BookingDesk.Store.reminder_jobs(),
            submissions: submissions,
            stale_results: s.stale,
            source_sha256: s.source_sha256,
            library_source_sha256: s.library_source_sha256,
            caller: caller_metadata(s),
            ambience: ambience,
            synthetic_caller: s.mode == :replay
          },
          assessment
        )
      )

    fields =
      if s.mode == :microphone,
        do: [:provider, :mode, :outcome, :evaluation, :observed],
        else: [:provider, :outcome, :passed, :checks]

    IO.puts(JSON.encode!(Map.take(report, fields)))
    report
  end

  defp caller_metadata(%{mode: :replay} = s) do
    s.clips
    |> Path.join("manifest.json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.take(["model", "voice_id", "voice", "sample_rate", "utterances"])
  end

  defp caller_metadata(_), do: nil

  defp flush(recorder) do
    receive do
      {:parlora_event, event} ->
        Recorder.event(recorder, event)
        flush(recorder)
    after
      0 -> :ok
    end
  end

  defp model,
    do:
      %{
        "openai" => "gpt-live-1",
        "gemini" => "gemini-3.8-live",
        "grok" => "grok-voice-3.0",
        "phonic" => "phonic-1"
      }[System.get_env("PARLORA_PROVIDER", "openai")]

  defp check_booked_exact_slot(s, appointments) do
    Enum.count(appointments, fn [id, _, slot, status, _] ->
      id != "appt_existing" &&
        slot ==
          BookingDesk.Store.slot_id(
            "2026-11-05",
            "10:15",
            if(s.any_doctor, do: "patel", else: "lee")
          ) && status == "booked"
    end) == 1
  end

  defp check_no_duplicate_availability(submissions) do
    Enum.count(submissions, &(&1.operation == "availability" && &1.date == "2026-11-04")) == 1 &&
      Enum.count(submissions, &(&1.operation == "availability" && &1.date == "2026-11-05")) ==
        1
  end

  defp check_correction_revision(submissions) do
    Enum.any?(
      submissions,
      &(&1.operation == "availability" && Map.get(&1, :date) == "2026-11-05" &&
          &1.revision > 1)
    )
  end

  defp check_scenario_completed(s, outcome) do
    outcome == :completed && s.stage == :done && booked?()
  end

  defp workflow_checks(s, outcome, appointments, submissions) do
    %{
      conversation_during_lookup: s.prep_during_work,
      announced_verified_confirmation: s.announced_confirmation,
      readback_before_confirmation: s.confirmation_readback,
      booked_exact_slot: check_booked_exact_slot(s, appointments),
      no_duplicate_availability: check_no_duplicate_availability(submissions),
      single_proposal: single_operation?(submissions, "propose"),
      single_booking_submission: single_operation?(submissions, "confirm"),
      correction_revision: check_correction_revision(submissions),
      stale_result_filtered: s.stale > 0,
      no_adapter_failure: s.failed == [],
      simulated_reminder_saved: reminder_saved?(s),
      single_reminder_submission: single_operation?(submissions, "reminder_confirm"),
      scenario_completed: check_scenario_completed(s, outcome)
    }
  end

  defp single_operation?(submissions, operation),
    do: Enum.count(submissions, &(&1.operation == operation)) == 1

  defp reminder_saved?(s) do
    case BookingDesk.Store.reminder_jobs() do
      [[appointment, _, destination, at, status, _]] ->
        appointment == s.booking_request and destination == "+12025550188" and
          at == "2026-11-04T17:15:00Z" and status == "simulated"

      _ ->
        false
    end
  end
end
