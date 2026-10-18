defmodule Parlora.ContextWaitTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, ContextDecision, ContextSnapshot, Limits}
  alias Parlora.Session.{ContextWait, Decisions, State}
  alias Parlora.TestSupport.CommandOwner

  defmodule Provider do
    def append_context(pid, update) do
      send(pid, {:context_update, update})
      :ok
    end
  end

  test "task clarification closes the correlated Gemini call and validates both references" do
    alias Parlora.Providers.Gemini.{Calls, Protocol}
    s = %{state() | adapters: %{provider: {Provider, self()}}}
    s = put_in(s.context.tasks, %{"t" => %{revision: 1}})

    d = %ContextDecision{
      kind: :request_clarification,
      task_id: "t",
      expected_task_revision: 1,
      delegation_id: "d",
      message: "No draft exists. What instruction?"
    }

    assert {:ok, next} = Decisions.apply_batch(s, [d])
    assert_receive {:context_update, update}
    assert update.delegation_id == "d"
    assert next.context.tasks["t"].clarification.message == d.message

    {:new, calls} =
      Calls.admit(Calls.new(16), %{
        "id" => "d",
        "name" => Protocol.function(),
        "args" => %{"request" => "Change instructions"}
      })

    assert {:ok, %{toolResponse: %{functionResponses: [%{id: "d"}]}}, calls} =
             Calls.context(calls, update.delegation_id, update.content)

    refute Calls.pending?(calls)

    assert {:error, %{code: :invalid_argument}} =
             Decisions.apply_batch(s, [%{d | expected_task_revision: 2}])

    assert {:error, %{code: :invalid_argument}} =
             Decisions.apply_batch(s, [%{d | delegation_id: "missing"}])

    assert {:error, %{code: :invalid_argument}} =
             Decisions.apply_batch(s, [d, %{d | task_id: nil, expected_task_revision: nil}])

    claimed = put_in(s.context.pending_delegations["d"].status, :claimed)
    assert {:error, %{code: :invalid_argument}} = Decisions.apply_batch(claimed, [d])
    refute_receive {:context_update, _}
  end

  defp state do
    %State{
      status: :ready,
      startup: %{%State{}.startup | owners: %{provider: CommandOwner.start()}},
      init: %AdapterInit{
        session_id: "wait-test",
        adapter_id: "wait-test",
        generation: 0,
        limits: %Limits{},
        event_sink: self()
      },
      limits: %Limits{},
      context: %ContextSnapshot{pending_delegations: %{"d" => %{status: :pending}}}
    }
  end

  defp wait(key) do
    %ContextDecision{
      kind: :wait_for_context,
      delegation_id: "d",
      recheck_after_ms: 60_000,
      recheck_key: key
    }
  end

  test "changed recheck keys replace one timer and reject already queued old expiry" do
    key = {:delegation, "d"}
    first = ContextWait.schedule(state(), wait("first"))
    {old_token, old_timer} = first.context_waits[key]
    assert ContextWait.schedule(first, wait("first")) == first
    second = ContextWait.schedule(first, wait("second"))
    assert map_size(second.context_waits) == 1
    assert Process.read_timer(old_timer) == false
    assert {^second, nil} = ContextWait.expire(second, key, old_token)
    {token, timer} = second.context_waits[key]
    Process.cancel_timer(timer)
    {expired, trigger} = ContextWait.expire(second, key, token)
    assert trigger.kind == :context_wait_expired
    assert expired.context.pending_delegations["d"].context_wait.expired?
    assert ContextWait.schedule(expired, wait("second")) == expired
    rearmed = ContextWait.schedule(expired, wait("verify"))
    refute rearmed.context.pending_delegations["d"].context_wait.expired?
    ContextWait.cancel(rearmed, key)
  end

  test "nil keys retain the original one-recheck behavior" do
    first = ContextWait.schedule(state(), wait(nil))
    assert ContextWait.schedule(first, wait(nil)) == first
    {token, timer} = first.context_waits[{:delegation, "d"}]
    Process.cancel_timer(timer)
    {expired, _trigger} = ContextWait.expire(first, {:delegation, "d"}, token)
    assert ContextWait.schedule(expired, wait(nil)) == expired
  end

  test "invalid recheck keys are rejected before scheduling" do
    for key <- ["", String.duplicate("a", 129), :invalid] do
      assert {:error, %{code: :invalid_argument}} = Decisions.apply_batch(state(), [wait(key)])
    end
  end

  test "clarification keys are bounded and new attempts respect session capacity" do
    decision = %ContextDecision{
      kind: :request_clarification,
      delegation_id: "d",
      message: "Which?"
    }

    for key <- ["", String.duplicate("a", 129), :invalid] do
      assert {:error, %{code: :invalid_argument}} =
               Decisions.apply_batch(state(), [%{decision | clarification_key: key}])
    end

    full = %{
      state()
      | limits: %Limits{max_records: 1},
        clarifications: MapSet.new([{"d", nil, nil, "first"}])
    }

    assert {:ok, ^full} = Decisions.apply_batch(full, [%{decision | clarification_key: "first"}])

    assert {:error, %{code: :backpressure}} =
             Decisions.apply_batch(full, [%{decision | clarification_key: "second"}])
  end

  test "clarifications retain the question and bounded application input" do
    input = %{known_order: "124", missing: ["operation"]}

    decision = %ContextDecision{
      kind: :request_clarification,
      delegation_id: "d",
      message: "Which information?",
      input: input
    }

    next = ContextWait.clarify(state(), decision, "question")

    assert next.context.pending_delegations["d"].clarification == %{
             context_revision: state().context.revision,
             command_id: "question",
             delivery: :unconfirmed,
             message: "Which information?",
             input: input
           }

    for invalid <- [nil, [], %{payload: String.duplicate("x", 4_096)}] do
      assert {:error, %{code: :invalid_argument}} =
               Decisions.apply_batch(state(), [%{decision | input: invalid}])
    end
  end
end
