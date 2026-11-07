defmodule BookingDesk.BookingSessionTest do
  use ExUnit.Case, async: false
  alias BookingDesk.CallGuard
  alias Parlora.{AudioFrame, AudioQueue, BackendResult, Event}

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
    def audio(pid, sequence), do: GenServer.call(pid, {:audio, sequence})

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
      {:ok, %{init: init, role: role, caps: caps, owner: opts[:owner], output: %AudioQueue{}}}
    end

    @impl true
    def handle_call(:capabilities, _, s), do: {:reply, {:ok, s.caps}, s}

    def handle_call({:read, budget}, _, s) do
      {frames, output} = AudioQueue.pop(s.output, budget)
      {:reply, {:ok, frames}, %{s | output: output}}
    end

    def handle_call({:write, _}, _, s), do: {:reply, :ok, s}

    def handle_call({:audio, sequence}, _, s) do
      frame = AudioFrame.pcm(:binary.copy(<<1000::signed-little-16>>, 240), "reply", sequence)
      {:ok, output} = AudioQueue.push(s.output, frame)
      {:reply, :ok, %{s | output: output}}
    end

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

  test "the recorded soccer, baseball and hockey turns play two native redirects and then the goodbye" do
    provider = start_scope_session()

    turns = [
      {"Hi, Eva. Do you know something about soccer?",
       "I'm just the scheduling desk here at Cedarwood Family Clinic, so I can't help with soccer questions. But if you need to book an appointment or anything clinic-related, I'm happy to help with that!"},
      {"Whether about baseball",
       "I can't help with baseball, but I'd be happy to assist with clinic appointments, registration, insurance, or reminders. What appointment help do you need?"},
      {"I want to talk about hockey.",
       "I'm not able to help with hockey, but I can schedule appointments, handle registration, insurance details, and reminders. What would you like to arrange?"}
    ]

    for {{question, reply}, index} <- Enum.with_index(turns, 1) do
      scope_turn(provider, question, reply, index)

      if index < 3 do
        assert_receive {:playout_active, _}, 1_000
      else
        assert_receive {:parlora_event, %Event{source: :provider, type: :control_completed}},
                       1_000

        refute_receive {:playout_active, _}, 150
      end

      scope_reply_finished(provider)

      if index < 3 do
        assert_receive {:scope, :scope_redirect, :native}, 1_000
        refute_received {:context, _}
      end
    end

    assert_receive {:scope, :scope_close, nil}, 1_000
    assert_receive {:context, goodbye}, 1_000
    assert goodbye.content =~ CallGuard.message(:scope_close)
    refute_received {:playout_active, _}
    refute_received {:parlora_event, %Event{source: :session, type: :closed}}

    assistant(provider, CallGuard.message(:scope_close), 8_000)
    Provider.audio(provider, 4)
    assert_receive {:playout_active, _}, 1_000
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 1_000
    refute_received {:scope, :scope_redirect, _}
    refute_received {:context, _}
    refute_received {:submitted, _}
  end

  test "the recorded Phonic turns play the goodbye without waiting for the third native reply" do
    provider =
      start_scope_session(scope_close_audio: CallGuard.scope_close_audio(), debounce_ms: 650)

    reply = CallGuard.message(:scope_redirect)

    questions = ["Hi, Eva. Do you know something about baseball?", "I want to talk about boxing."]

    for {question, index} <- Enum.with_index(questions, 1) do
      scope_turn(provider, question, reply, index)
      assert_receive {:playout_active, _}, 1_000
      scope_reply_finished(provider)
      assert_receive {:scope, :scope_redirect, :native}, 1_500
    end

    started = System.monotonic_time(:millisecond)
    scope_turn(provider, "Do you know what is the current president of US?", reply, 3)

    assert_receive {:scope, :scope_close, :recorded}, 1_500
    assert_receive {:playout_active, first_voice}, 1_000
    assert first_voice - started < 1_500

    # The third native reply can remain active past the entire goodbye.
    assistant(provider, "What would you like to arrange?", 7_500)
    Provider.audio(provider, 4)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 10_000
    assert System.monotonic_time(:millisecond) - first_voice >= 7_200
    refute_received {:scope, :scope_redirect, _}
    refute_received {:context, _}
    refute_received {:submitted, _}
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
    # The judge notification precedes retention. Do not advance the caller and
    # cancel that worker before the original preference has been saved.
    case :sys.get_state(session).policy_task do
      %{pid: pid} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 4_000

      nil ->
        :ok
    end

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

  test "the recorded Phonic flow accepts the first number-on-file confirmation and plays one goodbye" do
    owner = self()
    attempts = :atomics.new(1, [])
    correction = "Actually, I want to change the date. I prefer November fifth."

    guard =
      start_supervised!(
        {CallGuard,
         event_sink: self(),
         evaluator: fn _ -> {:ok, :allowed} end,
         farewell_audio: CallGuard.farewell_audio(),
         debounce_ms: 20,
         quiet_ms: 30}
      )

    judge = fn state ->
      {intent, date} =
        case state.latest_user do
          "Jamie Rivera, March 12, 1990." ->
            {"lookup", "2026-11-04"}

          "Yes. That is correct." ->
            {"insurance_same", "2026-11-04"}

          "Do you know what I need to bring to the appointment?" ->
            {"none", "2026-11-04"}

          ^correction ->
            if :atomics.add_get(attempts, 1, 1) <= 2 do
              send(owner, {:correcting_date, self()})
              receive do: (:continue -> :ok)
            end

            {"replace_search", "2026-11-05"}

          "The last option." ->
            {"choose_slot", "2026-11-05"}

          "Yes, please." ->
            {"confirm", "2026-11-05"}
        end

      {:ok, %{"intent" => intent, "date" => date, "clinician" => "lee", "time" => "14:00"}}
    end

    {_session, provider, backend} =
      start_session(
        judge,
        [
          call_guard: guard,
          phonic_busy: true,
          identity_extractor: fn _ -> {:ok, %{name: "jamie rivera", dob: "1990-03-12"}} end,
          reminder_judge: fn _ -> flunk("the verified readback and yes should need no judge") end,
          phone_extractor: fn _ -> flunk("the caller did not supply a replacement number") end
        ],
        false
      )

    caller(provider, "Jamie Rivera, March 12, 1990.", 0, "lookup")

    assert_receive {:submitted, %{input: %{operation: "lookup", date: "2026-11-04"}} = lookup},
                   2_000

    Provider.complete(backend, lookup)
    assert_receive {:context, insurance_question}, 2_000
    assistant(provider, insurance_question.content, 1_000)
    caller(provider, "Yes. That is correct.", 2_000, "insurance")
    assert_receive {:submitted, %{input: %{operation: "insurance"}} = insurance}, 2_000

    Provider.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "Do you know what I need to bring to the appointment?"
    })

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Do you know" <> _}}}

    Provider.complete(backend, insurance)
    assert_receive {:context, %{content: "The caller confirmed their insurance" <> _}}, 2_000

    assistant(
      provider,
      "While I'm checking those times, bring a photo ID and your insurance card.",
      3_000
    )

    Provider.inject(provider, :transcript_delta, %{speaker: :user, delta: correction})
    assert_receive {:correcting_date, first}, 2_000
    Provider.inject(provider, :delegation_requested, %{id: "change", target: :client})

    assert_receive {:parlora_event,
                    %Event{type: :delegation_pending, payload: %{delegation_id: "change"}}}

    send(first, :continue)
    assert_receive {:correcting_date, active}, 2_000

    Provider.inject(provider, :provider_speech, %{state: :speaking})
    assistant(provider, "Sure, let me check November 5th with Dr. Lee instead.", 4_000)

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Sure, let me check" <> _}}}

    send(active, :continue)

    assert_receive {:submitted,
                    %{input: %{operation: "availability", date: "2026-11-05"}} = search},
                   2_000

    assert search.delegation_id == "change"
    assert search.task_revision == 1
    assert :atomics.get(attempts, 1) == 2
    Provider.inject(provider, :provider_speech, %{state: :idle})
    Provider.complete(backend, search)

    assert_receive {:context, %{content: "Verified availability for Thursday November 5" <> _}},
                   2_000

    assistant(
      provider,
      "Dr. Lee has 10:15 AM or 2:00 PM on Thursday, November 5th. Which works better?",
      5_000
    )

    caller(provider, "The last option.", 6_000, "slot")
    assert_receive {:submitted, %{input: %{operation: "propose"}} = proposal}, 2_000
    Provider.complete(backend, proposal)
    assert_receive {:context, readback}, 2_000

    assistant(provider, readback.content, 7_000)
    caller(provider, "Yes, please.", 8_000, "booking")
    assert_receive {:submitted, %{input: %{operation: "confirm"}} = booking}, 4_000
    Provider.complete(backend, booking)
    assert_receive {:context, receipt}, 2_000

    assistant(
      provider,
      "You're booked. Would you like a text reminder 24 hours before your appointment?",
      10_000
    )

    assert receipt.content =~ "Booked: Thursday November 5 at 2:00 PM"

    caller(provider, "Yes, please.", 12_000, "opt-in")
    assert_receive {:submitted, %{input: %{operation: "reminder_opt_in"}} = opt_in}, 4_000
    Provider.complete(backend, opt_in)
    assert_receive {:context, destination}, 2_000
    assert destination.content =~ "zero one eight eight"
    assert BookingDesk.Store.reminder_jobs() == []

    readback = "Can we send the reminder to the number on file ending in zero one eight eight?"
    assistant(provider, readback, 14_000, "first-readback")
    caller(provider, "Yes. That is my number.", 15_000, "first-consent")
    assert_receive {:submitted, %{input: %{operation: "reminder_confirm"}} = reminder}, 4_000
    assert reminder.input.destination == "+12025550188"
    assert reminder.input.reminder_revision == opt_in.id
    Provider.complete(backend, reminder)

    assert_receive {:context, %{content: "Your text reminder is scheduled" <> _}}, 2_000
    assert [[_, "p_1002", "+12025550188", _, "simulated", _]] = BookingDesk.Store.reminder_jobs()
    refute_received {:parlora_event, %Event{type: :clarification_requested}}

    assistant(
      provider,
      "Your text reminder's all set for 24 hours before your appointment.",
      17_000
    )

    caller(provider, "Thank you. Bye.", 18_000, "farewell")

    assert_receive {:parlora_event, %Event{source: :channel, type: :control_completed}}, 2_000
    Provider.inject(provider, :provider_speech, %{state: :speaking})
    assistant(provider, "The reminder has been confirmed.", 19_000)
    Provider.audio(provider, 3)

    assert_receive {:playout_active, first_voice}, 1_000
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 5_000
    assert System.monotonic_time(:millisecond) - first_voice >= 1_700
    assert length(BookingDesk.Store.reminder_jobs()) == 1
    refute_received {:context, _}
    refute_receive {:submitted, _}, 100
  end

  test "the GPT-Live replay says the changed date and advances on the first yes after niner" do
    correction = "Actually, I changed my mind. What about November fifth"

    judge = fn state ->
      {intent, date} =
        case state.latest_user do
          "November fourth with Dr. Lee" -> {"availability", "2026-11-04"}
          ^correction -> {"replace_search", "2026-11-05"}
          "The one afternoon" -> {"choose_slot", "2026-11-05"}
          "Yes, please" -> {"confirm", "2026-11-05"}
        end

      {:ok, %{"intent" => intent, "date" => date, "clinician" => "lee", "time" => "14:00"}}
    end

    {_session, provider, backend} =
      start_session(judge,
        reminder_judge: fn _ -> flunk("the recorded exact consent needs no reminder judge") end,
        phone_extractor: fn _ -> flunk("the caller did not supply a new phone number") end
      )

    caller(provider, "November fourth with Dr. Lee", 0, "original")
    assert_receive {:submitted, %{input: %{operation: "availability", date: "2026-11-04"}} = old}
    caller(provider, correction, 2_000, "corrected")

    assert_receive {:submitted,
                    %{input: %{operation: "availability", date: "2026-11-05"}} = search},
                   2_000

    Provider.complete(backend, search)
    assert_receive {:context, availability}, 2_000

    options =
      "For Thursday November 5, Dr. Lee has 10:15 AM or 2:00 PM. Which time works for you?"

    assert availability.content =~ options
    Provider.complete(backend, old)
    assert_receive {:parlora_event, %Event{type: :stale_result}}, 2_000
    assistant(provider, options, 4_000)

    caller(provider, "The one afternoon", 6_000, "slot")

    assert_receive {:submitted,
                    %{input: %{operation: "propose", slot: "2026-11-05T14:00:00"}} = proposal},
                   2_000

    Provider.complete(backend, proposal)
    assert_receive {:context, proposal_readback}, 2_000
    assistant(provider, proposal_readback.content, 8_000)

    caller(provider, "Yes, please", 10_000, "booking")
    assert_receive {:submitted, %{input: %{operation: "confirm"}} = booking}, 4_000
    Provider.complete(backend, booking)
    assert_receive {:context, %{content: "Booked: Thursday November 5 at 2:00 PM" <> _}}, 2_000

    # Bind the fake provider's spoken receipt to the same code as the recording.
    db = :sys.get_state(BookingDesk.Store)

    {:ok, statement} =
      Exqlite.Sqlite3.prepare(db, "UPDATE appointments SET confirmation = ? WHERE id = ?")

    :ok = Exqlite.Sqlite3.bind(statement, ["BD-94C40748", booking.id])
    :done = Exqlite.Sqlite3.step(db, statement)
    :ok = Exqlite.Sqlite3.release(db, statement)

    assistant(
      provider,
      "Your confirmation number is B as in Bravo, D as in Delta, dash niner four C as in Charlie, four, zero, seven, four, eight. Would you like a text reminder 24 hours before your appointment?",
      12_000
    )

    for {text, at} <- [{" Yes,", 13_000}, {" that will", 13_400}, {" be great", 13_800}] do
      Provider.inject(provider, :transcript_delta, %{
        speaker: :user,
        delta: text,
        start_ms: at,
        end_ms: at + 200
      })
    end

    # GPT-Live did not open a tool call on this turn in the recording.
    assert_receive {:submitted, %{input: %{operation: "reminder_opt_in"}} = opt_in}, 4_000
    assert opt_in.input.booking_request == booking.id
    assert opt_in.delegation_id == nil
    assert BookingDesk.Store.reminder_jobs() == []

    Provider.inject(provider, :delegation_requested, %{id: "late-opt-in", target: :client})

    assert_receive {:parlora_event,
                    %Event{type: :delegation_associated, payload: %{id: "late-opt-in"}}}

    Provider.complete(backend, opt_in)
    assert_receive {:context, destination}, 2_000

    assert destination.content =~ "Can we send it to the number ending in zero one eight eight?"

    refute_received {:parlora_event, %Event{type: :clarification_requested}}
    assert BookingDesk.Store.reminder_jobs() == []

    assistant(provider, "Can we send it to the number ending in zero one eight eight?", 16_000)
    caller(provider, "Yes, that is my number", 18_000, "number")
    assert_receive {:submitted, %{input: %{operation: "reminder_confirm"}} = reminder}, 4_000
    Provider.complete(backend, reminder)
    assert_receive {:context, %{content: "Your text reminder is scheduled" <> _}}, 2_000
    assert [[_, "p_1002", "+12025550188", _, "simulated", _]] = BookingDesk.Store.reminder_jobs()
    refute_receive {:submitted, _}, 100
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

  defp start_reminder_flow(policy_opts) do
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

  test "neutral reminder wording resumes with opt-in and still waits for separate number consent" do
    {session, provider, backend} =
      start_reminder_flow(
        reminder_judge: fn state ->
          if state.latest_user == "Is it booked yet?",
            do: {:ok, "appointment"},
            else: flunk("the recorded offer and clear consent must not need a reminder model")
        end
      )

    assistant(provider, "Would you like a text reminder twenty-four hours before?", 12_000)
    caller(provider, "Yeah, that'd be helpful", 14_000, "opt-in")
    assert_receive {:submitted, optin}, 4_000
    assert optin.input.operation == "reminder_opt_in"

    refute_receive {:context,
                    %{
                      content:
                        "Would you like a text reminder 24 hours before your appointment?" <> _
                    }},
                   100

    assert BookingDesk.Store.reminder_jobs() == []
    Provider.complete(backend, optin)
    assert_receive {:context, destination}, 2_000
    assert destination.content =~ "Can we send it to the number ending in zero one eight eight?"

    for text <- ["Can we send it to the number ending in zero one ", "eight eight?"] do
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
    caller(provider, "Yep, that's the right number", 18_000, "number-consent")
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
              flunk("a fresh clear answer to the clarification must not need JEV")

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

  defp start_scope_session(opts \\ []) do
    guard =
      start_supervised!(
        {CallGuard,
         Keyword.merge(
           [
             event_sink: self(),
             evaluator: fn _ -> {:ok, :off_topic} end,
             native_result_replies: true,
             debounce_ms: 0,
             quiet_ms: 30
           ],
           opts
         )}
      )

    {session, provider, _backend} =
      start_session(
        fn _ -> flunk("off-topic speech cannot reach scheduling") end,
        [call_guard: guard],
        false
      )

    test_id = make_ref()
    session_id = Parlora.snapshot(session).session_id

    :ok =
      :telemetry.attach(
        test_id,
        [:booking_desk, :guard, :stop],
        fn _, _, metadata, {owner, id} ->
          if metadata.session_id == id,
            do: send(owner, {:scope, metadata.outcome, metadata[:delivery]})
        end,
        {self(), session_id}
      )

    on_exit(fn -> :telemetry.detach(test_id) end)

    provider
  end

  defp scope_turn(provider, question, reply, index) do
    item = "scope-#{index}"

    Provider.inject(provider, :extension, %{
      kind: :caller_speech,
      state: :started,
      segment_id: item
    })

    Provider.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: question,
      segment_id: item,
      start_ms: index * 2_000,
      end_ms: index * 2_000 + 500
    })

    Provider.inject(provider, :provider_speech, %{state: :speaking})
    Provider.inject(provider, :provider_activity, %{state: :in_progress})
    assistant(provider, reply, index * 2_000 + 750)
    Provider.audio(provider, index)
  end

  defp scope_reply_finished(provider) do
    Provider.inject(provider, :provider_speech, %{state: :idle})
    Provider.inject(provider, :provider_activity, %{state: :idle})
  end

  defp start_session(judge, policy_opts \\ [], registered? \\ true) do
    {:ok, memory} = start_supervised(BookingDesk.Conversation)
    policy = Keyword.merge([conversation: memory, judge: judge, coalesce_ms: 0], policy_opts)
    guard = policy_opts[:call_guard]
    channel_opts = if guard, do: [audio_observer: CallGuard.observer(guard)], else: []

    {:ok, session} =
      Parlora.start_session(
        channel: {BookingDesk.ReplayChannel, [owner: self()] ++ channel_opts},
        provider: {Provider, owner: self()},
        backend: {Backend, owner: self()},
        context_policy: {BookingDesk.Policy, policy},
        event_sink: guard || self()
      )

    on_exit(fn ->
      if Process.alive?(session) do
        ref = Process.monitor(session)
        Parlora.close(session)
        assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000
      end
    end)

    :ok = BookingDesk.Conversation.bind(memory, session)
    if guard, do: :ok = CallGuard.bind(guard, session)
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

  defp assistant(provider, text, start_ms, segment_id \\ nil) do
    Provider.inject(provider, :transcript_delta, %{
      speaker: :assistant,
      delta: text,
      segment_id: segment_id,
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
