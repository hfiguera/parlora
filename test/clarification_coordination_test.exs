defmodule Parlora.ClarificationCoordinationTest do
  use ExUnit.Case, async: true
  alias Parlora.{ContextDecision, ContextSnapshot, Limits}
  alias Parlora.Session.{Commands, ContextWait, Decisions, State}
  alias Parlora.TestSupport.CommandOwner

  defmodule Provider do
    def append_context({owner, outcome}, update) do
      send(owner, {:update, update})
      outcome
    end
  end

  defp state(outcome \\ :ok) do
    %State{
      status: :ready,
      startup: %{%State{}.startup | owners: %{provider: CommandOwner.start()}},
      init: %Parlora.AdapterInit{
        session_id: "clarify",
        adapter_id: "session",
        generation: 0,
        limits: %Limits{},
        event_sink: self()
      },
      limits: %Limits{},
      adapters: %{provider: {Provider, {self(), outcome}}},
      context: %ContextSnapshot{
        provider_generation: 0,
        pending_delegations: %{"call" => %{status: :pending}}
      }
    }
  end

  defp question do
    %ContextDecision{
      kind: :request_clarification,
      delegation_id: "call",
      clarification_key: "caller-1",
      message: "Which order?"
    }
  end

  test "speaking defers without submission or a fictitious clarification boundary" do
    {:ok, state} = Decisions.apply_batch(%{state() | provider_speech: :speaking}, [question()])
    refute_receive {:update, _}, 20
    refute Map.has_key?(state.context.pending_delegations["call"], :clarification)
    assert MapSet.size(state.clarifications) == 0
    assert_receive {:context_wait, key, token}, 750
    {state, trigger} = ContextWait.expire(state, key, token)
    assert trigger.kind == :context_wait_expired

    # Re-evaluation can discard an obsolete question; no command was queued.
    {:ok, state} = Decisions.apply_batch(%{state | provider_speech: :idle}, [])
    refute_receive {:update, _}, 20
    assert state.context_waits == %{}
  end

  test "fresh policy may submit after speech; repeated decision stays idempotent" do
    state = %{state() | provider_speech: :idle}
    {:ok, state} = Decisions.apply_batch(state, [question()])
    assert_receive {:update, update}
    assert state.context.pending_delegations["call"].clarification.delivery == :unconfirmed
    assert state.context.pending_delegations["call"].clarification.command_id == update.id
    {:ok, _state} = Decisions.apply_batch(state, [question()])
    refute_receive {:update, _}, 20
  end

  test "rejected admission records neither a submitted question nor a deduplication key" do
    error = Parlora.Error.tuple(:backpressure, "Try later")
    {:ok, state} = Decisions.apply_batch(state(error), [question()])
    assert_receive {:update, _}
    assert_receive {:parlora_command_result, reference, reply}
    state = Commands.result(state, reference, reply)
    refute Map.has_key?(state.context.pending_delegations["call"], :clarification)
    assert MapSet.size(state.clarifications) == 0
    {:ok, _state} = Decisions.apply_batch(%{state | adapters: state().adapters}, [question()])
    assert_receive {:update, _}
  end
end
