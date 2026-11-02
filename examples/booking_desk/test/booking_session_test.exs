defmodule BookingDesk.BookingSessionTest do
  use ExUnit.Case, async: false
  alias Parlora.{BackendResult, Event}

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
    {:ok, memory} = start_supervised(BookingDesk.Conversation)

    judge = fn state ->
      cond do
        state.latest_user == "November fourth with Dr. Lee" ->
          {:ok, %{"intent" => "availability", "date" => "2026-11-04", "clinician" => "lee"}}

        state.latest_user == "What about November fifth?" ->
          {:incomplete, %{"date" => "2026-11-05", "clinician" => "lee"}, ["intent"]}

        state.latest_user == "Are you still checking?" ->
          assert state.verified_offers == []
          {:ok, %{"intent" => "progress"}}

        state.latest_user == "Change the search to November fifth" ->
          assert state.pending_request["date"] == "2026-11-05"
          {:ok, %{"intent" => "replace_search", "date" => "2026-11-05", "clinician" => "lee"}}

        state.latest_user == "The morning one" ->
          assert Enum.all?(state.verified_offers, &(&1.date == "2026-11-05"))

          {:ok,
           %{
             "intent" => "choose_slot",
             "date" => "2026-11-05",
             "time" => "10:15",
             "clinician" => "lee"
           }}

        state.latest_user in ["Yes, if my insurance covers it", "Yes, please book it"] ->
          {:ok,
           %{
             "intent" => "confirm",
             "date" => "2026-11-05",
             "time" => "10:15",
             "clinician" => "lee"
           }}
      end
    end

    {:ok, session} =
      Parlora.start_session(
        channel: {BookingDesk.ReplayChannel, owner: self()},
        provider: {Provider, owner: self()},
        backend: {Backend, owner: self()},
        context_policy: {BookingDesk.Policy, conversation: memory, judge: judge, coalesce_ms: 0},
        event_sink: self()
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    :ok = BookingDesk.Conversation.bind(memory, session)
    assert_receive {:provider, provider}
    assert_receive {:backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, 5_000
    :ok = Parlora.update_context(session, registration(Parlora.snapshot(session).session_id))

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

    caller(provider, "Change the search to November fifth", 6_000, "replacement")
    assert_receive {:submitted, replacement}, 2_000
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

    caller(provider, "Yes, if my insurance covers it", 10_000, "conditional")
    assert_receive {:context, consent_question}, 4_000
    assert consent_question.content =~ "explicitly confirm"
    refute_receive {:submitted, _}, 50
    assert BookingDesk.Store.snapshot() == appointments

    assistant(provider, readback.content, 11_000)
    caller(provider, "Yes, please book it", 12_000, "approval")
    assert_receive {:submitted, confirmation}, 2_000
    assert confirmation.input.operation == "confirm"
    assert confirmation.input.proposal == proposal.id
    assert confirmation.input.revision == proposal.input.revision
    refute_receive {:parlora_event, %Event{type: :policy_rejected}}, 30
    refute_receive {:submitted, _}, 30
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
