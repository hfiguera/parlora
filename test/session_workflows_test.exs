defmodule Parlora.SessionWorkflowsTest do
  use ExUnit.Case, async: true
  alias Parlora.{ContextDecision, Event}

  alias Parlora.TestSupport.{
    ControlledPolicy,
    FakeBackend,
    MemoryAudio,
    MemoryChannel,
    MemoryProvider
  }

  for invalid <- [:malformed, :stale, :conflicting] do
    @invalid invalid
    test "a #{@invalid} decision after a valid start rejects the entire batch without effects" do
      {session, provider, _backend} = boot()
      delegate(provider)
      assert_receive {:policy, worker, _snapshot, _trigger}
      before = Parlora.snapshot(session)

      invalid =
        case @invalid do
          :malformed ->
            %{kind: :no_action}

          :stale ->
            %ContextDecision{kind: :update_task, task_id: "missing", expected_task_revision: 1}

          :conflicting ->
            start()
        end

      send(worker, {:decisions, [start(), invalid]})
      assert_receive {:parlora_event, %Event{type: :policy_rejected}}
      assert Parlora.snapshot(session) == before
      assert Parlora.status(session).jobs == %{}
      refute_receive {:submitted, _request}, 20
      refute_received {:context, _update}

      assert :ok = Parlora.update_context(session, %{retry: true})
      assert_receive {:policy, retry, _snapshot, _trigger}
      send(retry, {:decisions, [start()]})
      assert_receive {:submitted, request}
      assert request.task_revision == 1
      assert request.input == %{order: "123"}
      assert map_size(Parlora.snapshot(session).tasks) == 1
      refute_receive {:submitted, _duplicate}, 20
    end
  end

  test "recovery and a stale successful policy cannot release a result before fresh interpretation" do
    {session, provider, backend} = boot()
    delegate(provider)
    assert_receive {:policy, initial, _snapshot, _trigger}
    send(initial, {:decisions, [start()]})
    assert_receive {:submitted, request}

    assert :ok = Parlora.update_context(session, %{awaiting_confirmation: true})
    assert_receive {:policy, outdated, _snapshot, _trigger}
    assert :ok = FakeBackend.complete(backend, request, "Verified result")
    assert_receive {:parlora_event, %Event{type: :request_completed}}
    assert Parlora.status(session).jobs[request.id].delivery == :awaiting_interpretation

    inject(provider, :output_recovery_requested, %{token: 1, cause: :output_overflow})
    assert_receive {:output_recovery, 1, recovery}

    assert recovery.tasks[request.task_id].recovery_result == %{
             status: :completed,
             summary: "Verified result"
           }

    inject(provider, :output_recovered, %{token: 1})
    inject(provider, :transcript_delta, %{speaker: :user, delta: "please continue"})
    assert Parlora.status(session).output_recovery == nil

    send(outdated, {:decisions, []})
    assert_receive {:policy, fresh, snapshot, %{kind: :transcript_updated}}
    assert Enum.any?(snapshot.transcripts, &(&1.delta == "please continue"))
    assert Parlora.status(session).jobs[request.id].delivery == :awaiting_interpretation
    refute_receive {:context, _premature}, 20

    send(fresh, {:decisions, []})
    assert_receive {:context, %{content: "Verified result", task_revision: 1}}
    assert Parlora.status(session).status == :ready
    refute_receive {:submitted, _replayed_work}, 20
    refute_receive {:context, _duplicate}, 20
  end

  test "closing during recovery cancels interpretation and reports held completion without speaking it" do
    {session, provider, backend} = boot()
    delegate(provider)
    assert_receive {:policy, initial, _snapshot, _trigger}
    send(initial, {:decisions, [start()]})
    assert_receive {:submitted, request}
    assert :ok = Parlora.update_context(session, %{awaiting_confirmation: true})
    assert_receive {:policy, pending, _snapshot, _trigger}
    policy_monitor = Process.monitor(pending)
    session_monitor = Process.monitor(session)

    inject(provider, :output_recovery_requested, %{token: 2, cause: :output_overflow})
    assert_receive {:output_recovery, 2, _snapshot}
    assert :ok = FakeBackend.complete(backend, request, "Held completion")
    assert_receive {:parlora_event, %Event{type: :request_completed}}
    assert Parlora.status(session).jobs[request.id].delivery == :awaiting_interpretation

    assert :ok = Parlora.close(session, :finish)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed, payload: closed}}
    assert closed.jobs[request.id] == :completed
    assert_receive {:DOWN, ^policy_monitor, :process, ^pending, _reason}
    assert_receive {:DOWN, ^session_monitor, :process, ^session, :normal}
    refute_received {:context, _unapproved}
    refute_received {:submitted, _replayed_work}
    refute_received {:policy, _retry, _snapshot, _trigger}
  end

  defp start,
    do: %ContextDecision{kind: :start_task, delegation_id: "work", input: %{order: "123"}}

  defp delegate(provider),
    do: inject(provider, :delegation_requested, %{id: "work", offset_ms: 0})

  defp inject(provider, type, payload) do
    assert :ok = MemoryAudio.inject(provider, type, payload)
    assert_receive {:parlora_event, %Event{source: :provider, type: ^type}}
  end

  defp boot do
    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {MemoryProvider, observer: self()},
        backend: {FakeBackend, observer: self()},
        context_policy: {ControlledPolicy, observer: self()},
        event_sink: self(),
        limits: [shutdown_timeout_ms: 200]
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:adapter, :channel, _channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    {session, provider, backend}
  end
end
