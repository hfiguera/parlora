defmodule Parlora.QueuedDecisionsTest do
  use ExUnit.Case, async: true
  @startup_timeout 2_000
  alias Parlora.{ContextDecision, Event}
  alias Parlora.Session.Uncertainty
  alias Parlora.TestSupport.{ControlledPolicy, FakeBackend, MemoryAudio, MemoryChannel}

  defmodule Provider do
    def start_link(init, options) do
      Process.put(:queued_decisions_observer, options[:observer])
      MemoryAudio.start_link(init, :provider, options)
    end

    def control(pid, id, control) do
      send(Process.get(:queued_decisions_observer), {:held, self()})
      receive do: (:release -> :ok)
      MemoryAudio.control(pid, id, control)
    end

    def resolve_delegation(_pid, id, outcome) do
      send(Process.get(:queued_decisions_observer), {:resolved, id, outcome})
      :ok
    end

    defdelegate append_context(pid, update), to: MemoryAudio
    defdelegate read_audio(pid, budget), to: MemoryAudio
    defdelegate write_audio(pid, frame), to: MemoryAudio
    defdelegate close(pid, id, reason), to: MemoryAudio
  end

  test "an answered queued clarification never reaches the provider" do
    {session, provider, backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [question("lookup")])
    MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "Order 123"})
    decide(session, [start("lookup")])
    assert_receive {:submitted, request}
    FakeBackend.complete(backend, request, "Order 123 arrives tomorrow")

    eventually(fn ->
      Parlora.status(session).jobs[request.id][:delivery] == :awaiting_provider
    end)

    release(session, client, owner)
    assert_receive {:context, %{content: "Order 123 arrives tomorrow"}}
    refute_received {:context, %{content: "Which order number?"}}
    refute_received {:parlora_event, %Event{type: :clarification_requested}}
    assert MapSet.size(:sys.get_state(session).clarifications) == 0
  end

  test "a still-needed queued clarification is delivered once" do
    {session, provider, _backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [question("lookup")])
    release(session, client, owner)
    assert_receive {:context, %{content: "Which order number?"}}
    assert_receive {:parlora_event, %Event{type: :clarification_requested}}
    refute_received {:context, _duplicate}
  end

  test "changed context triggers a fresh clarification decision instead of the old question" do
    {session, provider, _backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [question("lookup")])
    MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "Please explain"})
    decide(session, [])
    release(session, client, owner)
    refute_received {:context, _old_question}
    revised = %{question("lookup") | message: "Please say the order number."}
    decide(session, [revised])
    assert_receive {:context, %{content: "Please say the order number."}}
    assert_receive {:parlora_event, %Event{type: :clarification_requested}}
    refute_received {:context, _duplicate}
  end

  test "a cancelled queued clarification neither speaks nor schedules another question" do
    {session, provider, _backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [question("lookup")])
    MemoryAudio.inject(provider, :delegation_cancelled, %{id: "lookup"})
    decide(session, [])
    release(session, client, owner)
    refute_received {:context, _question}
    assert :sys.get_state(session).context_waits == %{}
    assert :sys.get_state(session).policy_task == nil
  end

  test "dropping an older queued question preserves the replacement clarification" do
    {session, provider, _backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [question("lookup")])
    MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "A package"})

    replacement = %{
      question("lookup")
      | message: "Which package number?",
        clarification_key: "package"
    }

    decide(session, [replacement])
    release(session, client, owner)
    assert_receive {:context, %{content: "Which package number?"} = update}
    entry = Parlora.snapshot(session).pending_delegations["lookup"]
    assert entry.clarification.command_id == update.id
    refute_received {:context, _old_question}
    assert :sys.get_state(session).context_waits == %{}
  end

  test "a task clarification queued before an order correction is suppressed" do
    {session, provider, backend} = boot()
    delegate(provider, "lookup")
    decide(session, [start("lookup")])
    assert_receive {:submitted, first}
    {client, owner} = hold(session)
    assert :ok = Parlora.update_context(session, %{needs_clarification: true})

    clarify = %{
      question(nil)
      | task_id: first.task_id,
        expected_task_revision: first.task_revision
    }

    decide(session, [clarify])

    MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "Actually order 124"})

    decide(session, [
      %ContextDecision{
        kind: :supersede_task,
        task_id: first.task_id,
        expected_task_revision: first.task_revision,
        input: %{order: "124"}
      }
    ])

    assert_receive {:submitted, second}
    FakeBackend.complete(backend, second, "Corrected answer")
    eventually(fn -> Parlora.status(session).jobs[second.id][:delivery] == :awaiting_provider end)
    release(session, client, owner)
    assert_receive {:context, %{content: "Corrected answer"}}
    refute_received {:context, %{content: "Which order number?"}}
  end

  test "speech starting while a question is queued defers it until fresh policy approval" do
    {session, provider, _backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [question("lookup")])
    MemoryAudio.inject(provider, :provider_speech, %{state: :speaking})
    eventually(fn -> Parlora.status(session).provider_speech == :speaking end)
    release(session, client, owner)
    refute_received {:context, _old_question}
    MemoryAudio.inject(provider, :provider_speech, %{state: :idle})
    eventually(fn -> Parlora.status(session).provider_speech == :idle end)
    decide(session, [question("lookup")])
    assert_receive {:context, %{content: "Which order number?"}}
    assert_receive {:parlora_event, %Event{type: :clarification_requested}}
    refute_received {:context, _duplicate}
  end

  for terminal <- [:completed, :failed, :cancelled] do
    @terminal terminal
    test "an association queued while uncertain uses the current #{@terminal} result" do
      {session, provider, backend} = boot()
      {client, owner} = hold(session)
      delegate(provider, "lookup")
      decide(session, [start("lookup")])
      assert_receive {:submitted, request}

      FakeBackend.inject(backend, :request_uncertain, %{reason: :observer_exited},
        request_id: request.id
      )

      eventually(fn ->
        Parlora.status(session).jobs[request.id][:uncertainty_delivery] == :awaiting_provider
      end)

      delegate(provider, "duplicate")
      decide(session, [associate("duplicate", request)])
      FakeBackend.complete(backend, request, "Verified terminal answer", @terminal)

      eventually(fn ->
        Parlora.status(session).jobs[request.id][:delivery] == :awaiting_provider
      end)

      release(session, client, owner)
      assert_receive {:resolved, "duplicate", outcome}
      assert outcome.task_status == @terminal
      assert outcome.result == "Verified terminal answer"
      assert outcome.result_delivery == :awaiting_provider
      assert_receive {:context, %{content: "Verified terminal answer"}}
      uncertainty = Uncertainty.message()
      refute_received {:context, %{content: ^uncertainty}}
      refute_received {:submitted, _duplicate}
    end
  end

  test "an association cancelled before dispatch is not sent" do
    {session, provider, _backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [start("lookup")])
    assert_receive {:submitted, request}
    delegate(provider, "duplicate")
    decide(session, [associate("duplicate", request)])
    MemoryAudio.inject(provider, :delegation_cancelled, %{id: "duplicate"})
    decide(session, [])
    release(session, client, owner)
    refute_received {:resolved, "duplicate", _outcome}
    refute_received {:submitted, _duplicate}
  end

  test "a pending association reflects uncertainty that arose while queued" do
    {session, provider, backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [start("lookup")])
    assert_receive {:submitted, request}
    delegate(provider, "duplicate")
    decide(session, [associate("duplicate", request)])

    FakeBackend.inject(backend, :request_uncertain, %{reason: :observer_exited},
      request_id: request.id
    )

    eventually(fn ->
      Parlora.status(session).jobs[request.id][:uncertainty_delivery] == :awaiting_provider
    end)

    release(session, client, owner)
    assert_receive {:resolved, "duplicate", outcome}
    assert outcome.task_status == :uncertain
    assert outcome.result == Uncertainty.message()
    refute_received {:submitted, _duplicate}
  end

  test "an association for an obsolete task revision cannot replace a corrected answer" do
    {session, provider, backend} = boot()
    {client, owner} = hold(session)
    delegate(provider, "lookup")
    decide(session, [start("lookup")])
    assert_receive {:submitted, first}
    delegate(provider, "duplicate")
    decide(session, [associate("duplicate", first)])

    MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "Actually order 124"})

    decide(session, [
      %ContextDecision{
        kind: :supersede_task,
        task_id: first.task_id,
        expected_task_revision: first.task_revision,
        input: %{order: "124"}
      }
    ])

    assert_receive {:submitted, second}
    FakeBackend.complete(backend, second, "Corrected answer")
    eventually(fn -> Parlora.status(session).jobs[second.id][:delivery] == :awaiting_provider end)
    release(session, client, owner)
    assert_receive {:context, %{content: "Corrected answer"}}
    refute_received {:resolved, "duplicate", _obsolete_outcome}
  end

  test "a queued association reflects the latest provider acknowledgment" do
    {session, provider, backend} = boot(delay_context_ack: true)
    delegate(provider, "lookup")
    decide(session, [start("lookup")])
    assert_receive {:submitted, request}
    FakeBackend.complete(backend, request, "Verified answer")
    assert_receive {:context, update}

    eventually(fn ->
      Parlora.status(session).jobs[request.id][:delivery] == :awaiting_provider
    end)

    {client, owner} = hold(session)
    delegate(provider, "duplicate")
    decide(session, [associate("duplicate", request)])
    MemoryAudio.inject(provider, :context_acknowledged, %{}, command_id: update.id)
    eventually(fn -> Parlora.status(session).jobs[request.id].delivery == :accepted end)
    release(session, client, owner)
    assert_receive {:resolved, "duplicate", outcome}
    assert outcome.result_delivery == :accepted
    assert outcome.result == "Verified answer"
    refute_received {:context, _repeated_answer}
  end

  defp question(id),
    do: %ContextDecision{
      kind: :request_clarification,
      delegation_id: id,
      message: "Which order number?"
    }

  defp start(id),
    do: %ContextDecision{kind: :start_task, delegation_id: id, input: %{order: "123"}}

  defp associate(id, request),
    do: %ContextDecision{
      kind: :associate_delegation,
      delegation_id: id,
      task_id: request.task_id,
      expected_task_revision: request.task_revision
    }

  defp delegate(provider, id),
    do: MemoryAudio.inject(provider, :delegation_requested, %{id: id, offset_ms: 0})

  defp decide(session, decisions) do
    assert_receive {:policy, worker, snapshot, _trigger}

    if snapshot.revision == Parlora.snapshot(session).revision do
      send(worker, {:decisions, decisions})
      eventually(fn -> :sys.get_state(session).policy_task == nil end)
    else
      send(worker, {:decisions, []})
      decide(session, decisions)
    end
  end

  defp hold(session) do
    client = Task.async(fn -> Parlora.control(session, {:input_muted, true}, "hold") end)
    assert_receive {:held, owner}
    {client, owner}
  end

  defp release(session, client, owner) do
    send(owner, :release)
    assert :ok = Task.await(client)
    eventually(fn -> map_size(:sys.get_state(session).startup.commands.records) == 0 end)
  end

  defp boot(provider_options \\ []) do
    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, []},
        provider: {Provider, Keyword.merge([observer: self()], provider_options)},
        backend: {FakeBackend, observer: self()},
        context_policy: {ControlledPolicy, observer: self()},
        event_sink: self(),
        limits: [startup_timeout_ms: @startup_timeout, shutdown_timeout_ms: 100]
      )

    on_exit(fn -> if Process.alive?(session), do: Process.exit(session, :kill) end)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, @startup_timeout
    state = :sys.get_state(session)
    {session, elem(state.adapters.provider, 1), elem(state.adapters.backend, 1)}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(2)
      eventually(fun, attempts - 1)
    end
  end
end
