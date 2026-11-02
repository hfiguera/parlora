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

        state.latest_user == "The morning one" ->
          assert length(state.verified_offers) == 2
          assert Enum.all?(state.verified_offers, &(&1.date == "2026-11-05"))

          %{
            "intent" => "choose_slot",
            "date" => "2026-11-05",
            "time" => "morning",
            "clinician" => "lee"
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

    assistant(provider, result.content, 7_000)
    caller(provider, "The morning one", 8_000, "slot")
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

        "Ten fifteen" ->
          assert state.conversation.goal == "reschedule"

          {:ok,
           %{
             "intent" => "reschedule",
             "date" => "2026-11-05",
             "time" => "10:15",
             "clinician" => "lee"
           }}

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
    assistant(provider, available.content, 2_000)
    caller(provider, "Ten fifteen", 3_000, "replacement-slot")
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

  defp start_session(judge, policy_opts \\ []) do
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
    :ok = Parlora.update_context(session, registration(Parlora.snapshot(session).session_id))
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
