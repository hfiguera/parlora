defmodule BookingDesk.BookingSessionTest do
  use ExUnit.Case, async: false
  alias Parlora.{BackendResult, Event}

  setup do
    db = :sys.get_state(BookingDesk.Store)
    {:ok, saved} = Exqlite.Sqlite3.serialize(db)

    on_exit(fn ->
      :ok = Exqlite.Sqlite3.deserialize(db, saved)
    end)
  end

  defmodule Provider do
    use GenServer
    use Parlora.AdapterClient
    @behaviour Parlora.Provider

    def start_link(init, opts), do: GenServer.start_link(__MODULE__, {init, opts})
    def append_context(pid, update), do: GenServer.call(pid, {:context, update})
    def inject(pid, type, payload), do: GenServer.call(pid, {:inject, type, payload})
    def submit(pid, request), do: GenServer.call(pid, {:submit, request})
    def update(_pid, _id, _request_id, _request), do: :ok
    def cancel(_pid, _id, _request_id, _reason), do: :ok
    def complete(pid, request), do: GenServer.call(pid, {:complete, request})

    @impl true
    def init({init, opts}) do
      role = Keyword.get(opts, :role, :provider)

      caps =
        if role == :provider,
          do: %Parlora.Provider.Capabilities{
            audio_formats: [init.audio_format],
            full_duplex?: true,
            transcripts: [:user, :assistant],
            delegation_modes: [:client],
            context_update_kinds: [:speakable]
          },
          else: %Parlora.Backend.Capabilities{}

      send(opts[:owner], {role, self()})
      Event.emit(init, role, :ready, %{capabilities: caps, format: init.audio_format})
      {:ok, %{init: init, role: role, caps: caps, owner: opts[:owner]}}
    end

    @impl true
    def handle_call(:capabilities, _, s), do: {:reply, {:ok, s.caps}, s}
    def handle_call({:read, _}, _, s), do: {:reply, {:ok, []}, s}
    def handle_call({:write, _}, _, s), do: {:reply, :ok, s}

    def handle_call({:control, id, _}, _, s) do
      Event.emit(s.init, s.role, :control_completed, %{}, command_id: id)
      {:reply, :ok, s}
    end

    def handle_call({:close, id, _}, _, s) do
      Event.emit(s.init, s.role, :closed, %{finalized?: true}, command_id: id)
      {:reply, :ok, s}
    end

    def handle_call({:inject, type, payload}, _, s) do
      Event.emit(s.init, s.role, type, payload)
      {:reply, :ok, s}
    end

    def handle_call({:context, update}, _, s) do
      send(s.owner, {:context, update})
      Event.emit(s.init, s.role, :context_acknowledged, %{}, command_id: update.id)
      {:reply, :ok, s}
    end

    def handle_call({:submit, request}, _, s) do
      send(s.owner, {:submitted, request})
      {:reply, :ok, s}
    end

    def handle_call({:complete, request}, _, s) do
      stored = BookingDesk.Store.execute(request.input, request.id)

      result = %BackendResult{
        request_id: request.id,
        task_id: request.task_id,
        task_revision: request.task_revision,
        provider_generation: request.provider_generation,
        status: :completed,
        summary: stored["summary"],
        facts: stored["facts"]
      }

      Event.emit(s.init, s.role, :request_completed, result, request_id: request.id)
      {:reply, :ok, s}
    end
  end

  defmodule Backend do
    @behaviour Parlora.Backend
    def start_link(init, opts), do: Provider.start_link(init, Keyword.put(opts, :role, :backend))
    defdelegate capabilities(pid), to: Provider
    defdelegate close(pid, id, reason), to: Provider
    defdelegate submit(pid, request), to: Provider
    defdelegate update(pid, id, request_id, request), to: Provider
    defdelegate cancel(pid, id, request_id, reason), to: Provider
  end

  defmodule ClarificationChannel do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, %{owner: owner, drained: false})
    def init(state), do: {:ok, state}
    def handle_call(:output_drained, _, state), do: {:reply, state.drained, state}
    def handle_call({:drained, value}, _, state), do: {:reply, :ok, %{state | drained: value}}

    def handle_call({:play, pcm, label}, _, state) do
      send(state.owner, {:played, label, pcm})
      {:reply, :ok, state}
    end
  end

  test "Dr. Li survives registration as canonical Dr. Lee and insurance resumes the original search" do
    {_session, provider, backend, insurance} = register_doctor("li")
    assert insurance.input.clinician == "lee"
    Provider.complete(backend, insurance)
    assert_receive {:context, insurance_result}, 4_000
    assistant(provider, insurance_result.content, 8_000)
    assert_receive {:submitted, search}, 4_000
    assert search.input.operation == "availability"
    assert search.input.date == "2026-11-04"
    assert search.input.clinician == "lee"
    Provider.complete(backend, search)
    refute_receive {:submitted, _}, 100
    assert BookingDesk.Store.reminder_jobs() == []
  end

  test "a real doctor clarification replays the original preference once and cannot approve a booking" do
    {session, provider, backend, insurance} = register_doctor("unknown")
    Provider.complete(backend, insurance)
    assert_receive {:context, insurance_result}, 4_000
    assert insurance_result.content =~ "confirmed their insurance"
    assistant(provider, insurance_result.content, 8_000)
    assert_receive {:context, question}, 4_000
    assert question.content =~ "doctor"
    snapshot = Parlora.snapshot(session)
    task = snapshot.tasks[insurance.task_id]
    assert task.clarification.input.missing_fields == ["clinician"]
    assert task.clarification.input.booking_request["date"] == "2026-11-04"
    assert task.clarification.input.clinician_clarification.task_revision == task.revision
    refute_receive {:submitted, _}, 50

    {state, pcm, channel} = clarification_runner(session, insurance.input.lookup_request)
    assert BookingDesk.Run.advance(state).stage == :insurance
    refute_receive {:played, _, _}, 10
    :ok = GenServer.call(channel, {:drained, true})
    next = BookingDesk.Run.advance(state)
    assert next.stage == :clinician
    assert_receive {:played, "clinician", ^pcm}
    assert MapSet.size(next.clinician_replies) == 1

    assert BookingDesk.Run.advance(%{state | clinician_replies: next.clinician_replies}).stage ==
             :insurance

    refute_receive {:played, _, _}, 10

    capped = %{state | clinician_replies: MapSet.new(["earlier-question", "another-question"])}
    assert BookingDesk.Run.advance(capped).stage == :insurance
    refute_receive {:played, _, _}, 10

    before = BookingDesk.Store.snapshot()
    assistant(provider, question.content, 9_000)
    caller(provider, "Dr. Li on November fourth, please", 10_000, "doctor-reply")
    assert_receive {:submitted, search}, 4_000
    assert search.input.operation == "availability"
    assert search.input.date == "2026-11-04"
    assert search.input.clinician == "lee"
    assert search.input.lookup_request == insurance.input.lookup_request
    Provider.complete(backend, search)
    refute_receive {:submitted, _}, 100
    assert BookingDesk.Store.snapshot() == before
    assert BookingDesk.Store.reminder_jobs() == []
  end

  defp register_doctor(initial_doctor) do
    owner = self()

    judge = fn state ->
      {intent, date, clinician} =
        case state.latest_user do
          "I'd like Dr. Li on November fourth" ->
            send(owner, :initial_doctor_observed)
            {"availability", "2026-11-04", initial_doctor}

          "Jamie Rivera, March 12, 1990" ->
            {"lookup", "unknown", "unknown"}

          "Yep, same insurance" ->
            {"insurance_same", "unknown", "unknown"}

          "Dr. Li on November fourth, please" ->
            {"availability", "2026-11-04", "li"}
        end

      Map.new(%{"intent" => intent, "date" => date, "clinician" => clinician}, fn {key, value} ->
        {key, %{choice: value, probabilities: %{value => 0.99}}}
      end)
      |> BookingDesk.Judgment.decode(state)
    end

    {session, provider, backend} =
      start_session(
        judge,
        [identity_extractor: fn _ -> {:ok, %{name: "jamie rivera", dob: "1990-03-12"}} end],
        false
      )

    Provider.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "I'd like Dr. Li on November fourth",
      start_ms: 1_000,
      end_ms: 2_000
    })

    assert_receive :initial_doctor_observed, 4_000
    assistant(provider, "May I have your full name and date of birth?", 3_000)
    caller(provider, "Jamie Rivera, March 12, 1990", 4_000, "identity")
    assert_receive {:submitted, lookup}, 4_000
    assert lookup.input.operation == "lookup"
    assert lookup.input.date == "2026-11-04"
    assert lookup.input.clinician == if(initial_doctor == "li", do: "lee", else: nil)
    Provider.complete(backend, lookup)
    assert_receive {:context, insurance_question}, 4_000
    assert insurance_question.content =~ "Aetna"
    assistant(provider, insurance_question.content, 6_000)
    caller(provider, "Yep, same insurance", 7_000, "insurance")
    assert_receive {:submitted, insurance}, 4_000
    assert insurance.input.operation == "insurance"
    assert insurance.input.date == "2026-11-04"
    {session, provider, backend, insurance}
  end

  defp clarification_runner(session, lookup) do
    directory =
      Path.join(System.tmp_dir!(), "booking-doctor-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    pcm = :binary.copy(<<321::signed-little-16>>, 240)
    File.write!(Path.join(directory, "search.pcm"), pcm)
    channel = start_supervised!({ClarificationChannel, self()})

    recorder =
      start_supervised!({BookingDesk.Recorder, directory: Path.join(directory, "capture")})

    readback = start_supervised!({BookingDesk.Readback, []})
    now = System.monotonic_time(:millisecond)

    {%{
       mode: :replay,
       stage: :insurance,
       stage_at: now - 10_000,
       stage_due: 0,
       speech: :idle,
       last_audio_at: now - 2_000,
       text: "Which doctor would you like?",
       session: session,
       identity_request: lookup,
       channel: channel,
       recorder: recorder,
       readback: readback,
       clips: directory,
       readback_revision: 0,
       confirmation_readback: false,
       greeting_completed: true,
       any_doctor: false,
       clinician_replies: MapSet.new()
     }, pcm, channel}
  end

  test "a corrected search delivers only its result and booking still needs fresh unconditional approval" do
    judge = fn state ->
      cond do
        state.latest_user == "November fourth with Dr. Lee" ->
          {:ok, %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}

        state.latest_user == "What about November fifth?" ->
          {:incomplete, %{"date" => "2026-11-05", "clinician" => "lee"}, ["intent"]}

        state.latest_user == "Are you still checking?" ->
          assert state.verified_offers == []
          {:ok, %{"intent" => "progress"}}

        state.latest_user == "Yes" ->
          assert state.pending_request["date"] == "2026-11-05"

          if state.proposal == nil,
            do: {:error, :uncertain},
            else:
              {:ok,
               %{
                 "intent" => "confirm",
                 "date" => "2026-11-05",
                 "time" => "10:15",
                 "clinician" => "lee"
               }}

        state.latest_user == "The first one" ->
          assert length(state.verified_offers) == 2
          assert Enum.all?(state.verified_offers, &(&1.date == "2026-11-05"))

          %{
            "intent" => "choose_slot",
            "date" => "2026-11-05",
            "time" => "unknown",
            "clinician" => "unknown",
            "slot" => "2026-11-05/lee/10:15"
          }
          |> Map.new(fn {field, choice} ->
            {field, %{choice: choice, probabilities: %{choice => 0.99}}}
          end)
          |> BookingDesk.Judgment.decode(state)

        state.latest_user in ["Yes, if my insurance covers it", "Yes, please book it"] ->
          {:ok,
           %{
             "intent" => "confirm",
             "date" => "2026-11-05",
             "time" => "10:15",
             "clinician" => "lee"
           }}

        state.latest_user == "Maybe another date" ->
          {:error, :uncertain}

        state.latest_user == "Cancel that appointment" ->
          assert state.appointment.status == "booked"
          {:ok, %{"intent" => "cancel"}}

        state.latest_user == "Yes, please cancel it" ->
          assert state.proposal.change == "cancel"

          BookingDesk.Judgment.decode(
            %{"intent" => %{choice: "confirm", probabilities: %{"confirm" => 0.99}}},
            state
          )
      end
    end

    {_session, provider, backend} =
      start_session(judge,
        reminder_judge: fn state ->
          assert state.latest_user in ["Cancel that appointment", "Maybe another date"]
          {:ok, "appointment"}
        end
      )

    caller(provider, "November fourth with Dr. Lee", 0, "search")
    assert_receive {:submitted, old}, 2_000
    assert old.input.date == "2026-11-04"

    caller(provider, "What about November fifth?", 2_000, "correction")
    assert_receive {:context, question}, 4_000
    assert question.content =~ "November 5"
    assistant(provider, question.content, 3_000)
    refute_receive {:submitted, _}, 30

    Provider.complete(backend, old)
    assert_receive {:parlora_event, %Event{type: :request_completed}}, 1_000
    refute_receive {:context, _}, 50

    caller(provider, "Are you still checking?", 4_000, "progress")
    assert_receive {:context, clarification}, 2_000
    assert clarification.content =~ "November 5"
    assistant(provider, clarification.content, 5_000)
    refute_receive {:context, _}, 50
    refute_receive {:submitted, _}, 30

    caller(provider, "Yes", 6_000, "replacement")
    assert_receive {:submitted, replacement}, 4_000
    assert replacement.task_id == old.task_id
    assert replacement.task_revision == 2
    assert replacement.input.date == "2026-11-05"
    Provider.complete(backend, replacement)
    assert_receive {:context, result}, 2_000
    assert result.content =~ "November 5"
    refute result.content =~ "November 4"

    assistant(provider, "On November fifth, Dr. Lee has 10:15 AM or 2 PM. Which works?", 7_000)
    caller(provider, "The first one", 8_000, "slot")
    assert_receive {:submitted, proposal}, 2_000
    assert proposal.input.operation == "propose"
    assert proposal.input.slot == "2026-11-05T10:15:00"
    Provider.complete(backend, proposal)
    assert_receive {:context, readback}, 2_000
    assistant(provider, readback.content, 9_000)
    appointments = BookingDesk.Store.snapshot()

    caller(provider, "Yes", 10_000, "conditional")
    refute_receive {:submitted, _}, 300

    Provider.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: ", if my insurance covers it",
      start_ms: 10_400,
      end_ms: 11_200
    })

    assert_receive {:context, consent_question}, 4_000
    assert consent_question.content =~ "explicitly confirm"
    refute_receive {:submitted, _}, 50
    assert BookingDesk.Store.snapshot() == appointments

    assistant(provider, readback.content, 11_000)
    caller(provider, "Yes, please book it", 12_000, "approval")
    assert_receive {:submitted, confirmation}, 4_000
    assert confirmation.input.operation == "confirm"
    assert confirmation.input.proposal == proposal.id
    assert confirmation.input.revision == proposal.input.revision
    Provider.complete(backend, confirmation)
    assert_receive {:context, booked}, 2_000
    assert booked.content =~ "Booked"

    assistant(provider, "Would you like a text reminder?", 14_000)
    caller(provider, "Maybe another date", 15_000, "uncertain-appointment")
    assert_receive {:context, recovery_question}, 6_000
    refute recovery_question.content =~ "reminder"
    assistant(provider, recovery_question.content, 17_000)
    caller(provider, "Back to the reminder", 18_000, "resume-reminder")
    assert_receive {:context, reminder_question}, 2_000
    assert reminder_question.content =~ "text reminder"
    assistant(provider, reminder_question.content, 19_000)
    caller(provider, "Cancel that appointment", 20_000, "cancel")
    assert_receive {:submitted, cancellation}, 4_000
    assert cancellation.input.operation == "propose"
    assert cancellation.input.change == "cancel"
    assert cancellation.input.appointment == confirmation.id
    Provider.complete(backend, cancellation)
    assert_receive {:context, cancel_readback}, 2_000
    assistant(provider, cancel_readback.content, 22_000)
    caller(provider, "Yes, please cancel it", 23_000, "cancel-approval")
    assert_receive {:submitted, cancel_write}, 4_000
    assert cancel_write.input.proposal == cancellation.id
    Provider.complete(backend, cancel_write)
    assert_receive {:context, _cancelled}, 2_000
    appointments = BookingDesk.Store.snapshot()

    assert Enum.any?(appointments, fn [id, _, _, status, _] ->
             id == confirmation.id and status == "cancelled"
           end)

    assert Enum.any?(appointments, fn [id, _, _, status, _] ->
             id == "appt_existing" and status == "booked"
           end)

    refute_receive {:parlora_event, %Event{type: :policy_rejected}}, 30
    refute_receive {:submitted, _}, 30
  end

  test "date-only rescheduling checks availability and changes the original only after approval" do
    judge = fn state ->
      case state.latest_user do
        "Move my original appointment to November fifth with Dr. Lee" ->
          {:incomplete, %{"intent" => "reschedule", "date" => "2026-11-05", "clinician" => "lee"},
           ["time"]}

        "The second option" ->
          assert state.conversation.goal == "reschedule"
          assert Enum.any?(state.dialogue, &(&1.text =~ "2 PM or 10:15 AM"))

          %{
            "intent" => "choose_slot",
            "date" => "unknown",
            "time" => "unknown",
            "clinician" => "unknown",
            "slot" => "2026-11-05/lee/10:15"
          }
          |> Map.new(fn {field, choice} ->
            {field, %{choice: choice, probabilities: %{choice => 0.99}}}
          end)
          |> BookingDesk.Judgment.decode(state)

        "Yes, please" ->
          assert state.proposal.change == "reschedule"

          {:ok,
           %{
             "intent" => "confirm",
             "date" => "2026-11-05",
             "time" => "10:15",
             "clinician" => "lee"
           }}
      end
    end

    {_session, provider, backend} = start_session(judge)

    caller(
      provider,
      "Move my original appointment to November fifth with Dr. Lee",
      0,
      "reschedule"
    )

    assert_receive {:submitted, search}, 4_000
    assert search.input.operation == "availability"
    Provider.complete(backend, search)
    assert_receive {:context, available}, 2_000
    assert available.content =~ "November 5"
    assistant(provider, "Dr. Lee has 2 PM or 10:15 AM on November fifth. Which works?", 2_000)
    caller(provider, "The second option", 3_000, "replacement-slot")
    assert_receive {:submitted, proposal}, 2_000
    assert proposal.input.change == "reschedule"
    assert proposal.input.appointment == "appt_existing"
    Provider.complete(backend, proposal)
    assert_receive {:context, readback}, 2_000

    assert Enum.any?(BookingDesk.Store.snapshot(), fn [id, _, _, status, _] ->
             id == "appt_existing" and status == "booked"
           end)

    assistant(provider, readback.content, 5_000)
    caller(provider, "Yes, please", 6_000, "approve-reschedule")
    assert_receive {:submitted, confirmation}, 4_000
    assert confirmation.input.proposal == proposal.id
    Provider.complete(backend, confirmation)
    assert_receive {:context, result}, 2_000
    assert result.content =~ "Rescheduled"
    appointments = BookingDesk.Store.snapshot()

    assert Enum.any?(appointments, fn [id, _, _, status, _] ->
             id == "appt_existing" and status == "cancelled"
           end)

    assert Enum.any?(appointments, fn [id, _, _, status, _] ->
             id == confirmation.id and status == "booked"
           end)

    refute_receive {:submitted, _}, 30
  end

  test "a fragmented ambiguous choice settles before proposing and a fresh selection recovers" do
    judge = fn state ->
      if state.latest_user == "November fifth with Dr. Lee" do
        {:ok, %{"intent" => "availability", "date" => "2026-11-05", "clinician" => "lee"}}
      else
        slot =
          if state.latest_user == "The first or the second",
            do: "ambiguous",
            else: "2026-11-05/lee/10:15"

        %{"intent" => "choose_slot", "slot" => slot}
        |> Map.new(fn {field, choice} ->
          {field, %{choice: choice, probabilities: %{choice => 0.99}}}
        end)
        |> BookingDesk.Judgment.decode(state)
      end
    end

    {_session, provider, backend} = start_session(judge)
    appointments = BookingDesk.Store.snapshot()
    caller(provider, "November fifth with Dr. Lee", 0, "search")
    assert_receive {:submitted, search}, 2_000
    Provider.complete(backend, search)
    assert_receive {:context, _available}, 2_000
    assistant(provider, "Dr. Lee has 10:15 AM or 2 PM on November fifth. Which works?", 2_000)
    caller(provider, "The first", 3_000, "ambiguous")
    refute_receive {:submitted, _}, 300

    Provider.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: " or the second",
      start_ms: 3_400,
      end_ms: 4_200
    })

    assert_receive {:context, question}, 4_000
    assert question.content =~ "Which of the offered times"
    refute_receive {:submitted, _}, 50
    assert BookingDesk.Store.snapshot() == appointments

    assistant(provider, question.content, 5_000)
    caller(provider, "The first option", 6_000, "selection")
    assert_receive {:submitted, proposal}, 4_000
    assert proposal.input.operation == "propose"
    assert proposal.input.slot == "2026-11-05T10:15:00"
    Provider.complete(backend, proposal)
    assert_receive {:context, readback}, 2_000
    assert readback.content =~ "10:15"
    refute_receive {:submitted, _}, 50
    assert BookingDesk.Store.snapshot() == appointments
  end

  for code_fault <- [:none, :missing_pair, :streaming] do
    @code_fault code_fault
    if code_fault == :missing_pair, do: @tag(:confirmation_correction)

    test "phone recovery with confirmation correction #{@code_fault} requires fresh exact consent" do
      judge = fn state ->
        intent =
          case state.latest_user do
            "November fifth with Dr. Lee" -> "availability"
            "Ten fifteen" -> "choose_slot"
            "Yes, please book it" -> "confirm"
            "Is it booked yet?" -> "progress"
          end

        {:ok,
         %{
           "intent" => intent,
           "date" => "2026-11-05",
           "time" => "10:15",
           "clinician" => "lee"
         }}
      end

      {session, provider, backend} =
        start_session(judge,
          reminder_judge: fn state ->
            case state.latest_user do
              "Is it booked yet?" ->
                {:ok, "none"}

              "Yeah, that'd be helpful" ->
                {:ok, "opt_in"}

              "Yep, that's my cell" ->
                question = Enum.find(Enum.reverse(state.dialogue), &(&1.speaker == :assistant))
                refute question.text =~ "4289"
                assert BookingDesk.Reminders.readback?(question.text, "0188")
                {:ok, "confirm_number"}
            end
          end
        )

      caller(provider, "November fifth with Dr. Lee", 0, "search")
      assert_receive {:submitted, search}, 2_000
      Provider.complete(backend, search)
      assert_receive {:context, _available}, 2_000
      assistant(provider, "Dr. Lee has 10:15 AM or 2 PM on November fifth. Which works?", 2_000)
      caller(provider, "Ten fifteen", 3_000, "choose")
      assert_receive {:submitted, proposal}, 2_000
      Provider.complete(backend, proposal)
      assert_receive {:context, readback}, 2_000
      assistant(provider, readback.content, 5_000)
      caller(provider, "Yes, please book it", 6_000, "book")
      assert_receive {:submitted, booking}, 4_000

      if @code_fault != :none do
        assistant(provider, "Okay, I'm booking that now.", 7_200)

        Provider.inject(provider, :transcript_delta, %{
          speaker: :user,
          delta: "Is it booked yet?",
          start_ms: 8_000,
          end_ms: 8_500
        })
      end

      Provider.complete(backend, booking)
      assert_receive {:context, booked}, 2_000
      assert booked.content =~ "zero one eight eight"
      assert BookingDesk.Store.reminder_jobs() == []

      if @code_fault == :missing_pair do
        current = BookingDesk.ReminderPolicy.appointment(Parlora.snapshot(session))
        code = current.confirmation
        short = String.slice(code, 0, 5) <> String.slice(code, 7, 4)
        appointments = BookingDesk.Store.snapshot()

        assistant(
          provider,
          "Your confirmation number is #{short}. Would you like a text reminder?",
          9_000
        )

        assert_receive {:context,
                        %{content: "Let me correct the confirmation code." <> _} = repair},
                       4_000

        assert BookingDesk.Confirmation.complete?(repair.content, code)
        assert BookingDesk.Store.snapshot() == appointments
        refute_receive {:submitted, _}, 100
        assistant(provider, repair.content, 11_000)
      else
        if @code_fault == :streaming do
          code = BookingDesk.ReminderPolicy.appointment(Parlora.snapshot(session)).confirmation
          assistant(provider, "Your confirmation number is #{String.slice(code, 0, 6)}.", 9_000)
          refute_receive {:context, %{content: "Let me correct the confirmation code." <> _}}, 300

          assistant(
            provider,
            " #{String.slice(code, 6, 5)}. Would you like a text reminder?",
            9_600
          )

          refute_receive {:context, %{content: "Let me correct the confirmation code." <> _}},
                         2_200

          refute_receive {:submitted, _}, 50
        else
          assistant(provider, "You're booked. Would you like a text reminder?", 11_000)
        end
      end

      caller(provider, "Yeah, that'd be helpful", 13_000, "opt-in")
      assert_receive {:submitted, optin}, 4_000
      assert optin.input.operation == "reminder_opt_in"

      # The spoken guess precedes the verified result, exactly as in the live failure.
      assistant(
        provider,
        "Is your cell number ending in 4289 — can we send the reminder there?",
        15_000
      )

      Provider.complete(backend, optin)

      optin_id = optin.id

      assert_receive {:parlora_event, %Event{type: :request_completed, request_id: ^optin_id}},
                     2_000

      assert_receive {:context, %{content: "Let me correct that number." <> _} = correction},
                     4_000

      assert BookingDesk.Reminders.readback?(correction.content, "0188")
      refute_receive {:submitted, _}, 100
      assert BookingDesk.Store.reminder_jobs() == []

      assert Parlora.snapshot(session).tasks[optin.task_id].clarification.input.reminder_readback.request_id ==
               optin.id

      assistant(provider, correction.content, 17_000)
      caller(provider, "Yep, that's my cell", 19_000, "destination-consent")
      assert_receive {:submitted, confirmation}, 4_000
      assert confirmation.input.operation == "reminder_confirm"
      assert confirmation.input.destination == "+12025550188"
      assert confirmation.input.reminder_revision == optin.id
      Provider.complete(backend, confirmation)

      assert_receive {:context, %{content: "Your text reminder is scheduled" <> _}}, 2_000

      assert [[_, "p_1002", "+12025550188", _, "simulated", _]] =
               BookingDesk.Store.reminder_jobs()

      refute_receive {:submitted, _}, 100
    end
  end

  defp reminder_flow_judgment(state, owner) do
    intent =
      case state.latest_user do
        "November fifth with Dr. Lee" ->
          "availability"

        "Ten fifteen" ->
          "choose_slot"

        "Yes, please book it" ->
          "confirm"

        "Yeah, that'd be helpful" ->
          flunk(
            "a simple reply to the current exact reminder offer must not use booking classification"
          )

        "That sounds useful, I guess" ->
          "reminder"

        "Is it booked yet?" ->
          assert state.conversation.reminder_route == :suspended
          send(owner, :reminder_suspended)
          "progress"
      end

    {:ok, %{"intent" => intent, "date" => "2026-11-05", "time" => "10:15", "clinician" => "lee"}}
  end

  defp start_reminder_flow(policy_opts \\ []) do
    owner = self()

    judge = &reminder_flow_judgment(&1, owner)

    {session, provider, backend} =
      start_session(
        judge,
        Keyword.merge(
          [
            reminder_judge: fn state ->
              case state.latest_user do
                "Is it booked yet?" -> {:ok, "appointment"}
                "Yeah, that'd be helpful" -> {:ok, "opt_in"}
                "Yep, that's my cell" -> flunk("exact number consent needs no model")
              end
            end
          ],
          policy_opts
        )
      )

    caller(provider, "November fifth with Dr. Lee", 0, "search")
    assert_receive {:submitted, search}, 2_000
    Provider.complete(backend, search)
    assert_receive {:context, _availability}, 2_000
    assistant(provider, "Dr. Lee has 10:15 AM. Which time works?", 2_000)
    caller(provider, "Ten fifteen", 3_000, "choose")
    assert_receive {:submitted, proposal}, 2_000
    Provider.complete(backend, proposal)
    assert_receive {:context, proposal_readback}, 2_000
    assistant(provider, proposal_readback.content, 5_000)
    caller(provider, "Yes, please book it", 6_000, "book")
    assert_receive {:submitted, booking}, 4_000
    Provider.complete(backend, booking)
    assert_receive {:context, booked}, 2_000
    assistant(provider, booked.content, 8_000)
    caller(provider, "Is it booked yet?", 10_000, "progress")
    assert_receive :reminder_suspended, 4_000
    {session, provider, backend}
  end

  test "resuming with opt-in asks the destination once and still waits for separate number consent" do
    {session, provider, backend} = start_reminder_flow()

    assistant(provider, "Would you like a text reminder 24 hours before the appointment?", 12_000)
    caller(provider, "Yeah, that'd be helpful", 14_000, "opt-in")
    assert_receive {:submitted, optin}, 4_000
    assert optin.input.operation == "reminder_opt_in"

    refute_receive {:context,
                    %{content: "Would you like a text reminder for this appointment?" <> _}},
                   100

    assert BookingDesk.Store.reminder_jobs() == []
    Provider.complete(backend, optin)
    assert_receive {:context, destination}, 2_000
    assert destination.content =~ "zero one eight eight"

    for text <- ["Can we send the reminder to your cell ending in zero one ", "eight eight?"] do
      Provider.inject(provider, :transcript_delta, %{
        speaker: :assistant,
        delta: text,
        segment_id: "destination-reply",
        start_ms: nil,
        end_ms: nil
      })
    end

    snapshot = Parlora.snapshot(session)

    assert BookingDesk.ReminderReadback.verified?(
             snapshot,
             BookingDesk.ReminderPolicy.state(snapshot)
           )

    refute_receive {:context, _}, 100
    refute_receive {:submitted, _}, 100
    assert BookingDesk.Store.reminder_jobs() == []
    caller(provider, "Yep, that's my cell", 18_000, "number-consent")
    assert_receive {:submitted, confirmation}, 4_000
    assert confirmation.input.operation == "reminder_confirm"
    assert confirmation.input.destination == "+12025550188"
    assert confirmation.input.reminder_revision == optin.id
    Provider.complete(backend, confirmation)
    assert_receive {:context, %{content: "Your text reminder is scheduled" <> _}}, 2_000
    assert [[_, "p_1002", "+12025550188", _, "simulated", _]] = BookingDesk.Store.reminder_jobs()
    refute_receive {:submitted, _}, 100
  end

  test "a reminder clarification waits for fresh caller input instead of rejudging the same reply" do
    count = start_supervised!({Agent, fn -> 0 end})

    {session, provider, _backend} =
      start_reminder_flow(
        reminder_judge: fn state ->
          case state.latest_user do
            "Is it booked yet?" ->
              {:ok, "appointment"}

            "Yeah, that'd be helpful" ->
              {:ok, "opt_in"}

            "That sounds useful, I guess" ->
              if Agent.get_and_update(count, &{&1, &1 + 1}) == 0,
                do: {:error, :uncertain},
                else: {:ok, "opt_in"}
          end
        end,
        phone_extractor: fn _ -> {:incomplete, [:phone]} end
      )

    assistant(provider, "Would you like a text reminder?", 12_000)
    caller(provider, "That sounds useful, I guess", 14_000, "uncertain-opt-in")
    assert_receive {:context, question}, 4_000
    assert question.content =~ "Would you like a text reminder"
    snapshot = Parlora.snapshot(session)
    task = snapshot.tasks |> Map.values() |> Enum.find(&(&1.input.operation == "confirm"))
    assert task.clarification.input.reminder_clarification.caller_cursor > task.input.cursor
    assert Agent.get(count, & &1) == 1

    assistant(provider, question.content, 16_000)
    Provider.inject(provider, :delegation_requested, %{id: "duplicate-opt-in", target: :client})
    refute_receive {:submitted, _}, 300
    refute_receive {:context, _}, 100
    assert Agent.get(count, & &1) == 1
    assert BookingDesk.Store.reminder_jobs() == []

    caller(provider, "Yeah, that'd be helpful", 18_000, "fresh-opt-in")
    assert_receive {:submitted, optin}, 4_000
    assert optin.input.operation == "reminder_opt_in"
    assert optin.input.cursor > task.clarification.input.reminder_clarification.caller_cursor
    refute_receive {:submitted, _}, 100
    assert BookingDesk.Store.reminder_jobs() == []
  end

  defp start_session(judge, policy_opts \\ [], registered? \\ true) do
    {:ok, memory} = start_supervised(BookingDesk.Conversation)
    policy = Keyword.merge([conversation: memory, judge: judge, coalesce_ms: 0], policy_opts)

    {:ok, session} =
      Parlora.start_session(
        channel: {BookingDesk.ReplayChannel, owner: self()},
        provider: {Provider, owner: self()},
        backend: {Backend, owner: self()},
        context_policy: {BookingDesk.Policy, policy},
        event_sink: self()
      )

    on_exit(fn ->
      if Process.alive?(session) do
        ref = Process.monitor(session)
        Parlora.close(session)
        assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000
      end
    end)

    :ok = BookingDesk.Conversation.bind(memory, session)
    assert_receive {:provider, provider}
    assert_receive {:backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, 5_000

    if registered? do
      :ok = Parlora.update_context(session, registration(Parlora.snapshot(session).session_id))
    end

    {session, provider, backend}
  end

  defp caller(provider, text, start_ms, id) do
    Provider.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: text,
      start_ms: start_ms,
      end_ms: start_ms + 1_000
    })

    Provider.inject(provider, :delegation_requested, %{
      id: id,
      target: :client,
      offset_ms: start_ms
    })
  end

  defp assistant(provider, text, start_ms) do
    Provider.inject(provider, :transcript_delta, %{
      speaker: :assistant,
      delta: text,
      start_ms: start_ms,
      end_ms: start_ms + 500
    })
  end

  defp registration(session) do
    lookup = "session-lookup-#{System.unique_integer([:positive])}"
    review = lookup <> "-insurance"

    BookingDesk.Store.execute(
      %{operation: "lookup", name: "Jamie Rivera", dob: "1990-03-12", session: session},
      lookup
    )

    insurance = BookingDesk.Store.insurance(lookup, session)

    BookingDesk.Store.execute(
      %{
        operation: "insurance",
        patient: "p_1002",
        lookup_request: lookup,
        session: session,
        response: "unchanged",
        carrier: insurance.carrier,
        insurance_revision: insurance.revision
      },
      review
    )

    %{patient: "p_1002", lookup_request: lookup, insurance_request: review}
  end
end
