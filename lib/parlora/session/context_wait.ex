defmodule Parlora.Session.ContextWait do
  @moduledoc false
  alias Parlora.{ContextTrigger, ID}
  alias Parlora.Session.State

  def key(%{task_id: id, expected_task_revision: revision}) when is_binary(id),
    do: {:task, id, revision}

  def key(%{delegation_id: id}), do: {:delegation, id}

  def schedule(state, %{recheck_after_ms: nil}), do: state

  def schedule(state, decision) do
    key = key(decision)
    entry = entry(state, key)

    if match?(%{recheck_key: key} when key == decision.recheck_key, entry[:context_wait]) do
      state
    else
      state = cancel(state, key)
      token = ID.new()
      delay = decision.recheck_after_ms
      timer = Process.send_after(self(), {:context_wait, key, token}, delay)

      waiting = %{
        due_at_us: System.monotonic_time(:microsecond) + delay * 1_000,
        expired?: false,
        recheck_key: decision.recheck_key
      }

      state = put_entry(state, key, Map.put(entry, :context_wait, waiting))
      State.emit(state, :context_wait_started, %{target: key, recheck_after_ms: delay})
      %{state | context_waits: Map.put(state.context_waits, key, {token, timer})}
    end
  end

  def expire(state, key, token) do
    case state.context_waits[key] do
      {^token, _timer} ->
        entry = entry(state, key)
        state = cancel(state, key)
        state = put_entry(state, key, put_in(entry.context_wait.expired?, true))
        {state, trigger(key)}

      _stale ->
        {state, nil}
    end
  end

  def cancel(state, key) do
    case Map.pop(state.context_waits, key) do
      {nil, _waits} ->
        state

      {{_token, timer}, waits} ->
        Process.cancel_timer(timer)
        %{state | context_waits: waits}
    end
  end

  def clarify(state, decision, command_id) do
    key = key(decision)
    entry = entry(state, key)

    clarification = %{
      context_revision: state.context.revision,
      command_id: command_id,
      message: decision.message,
      delivery: :unconfirmed,
      input: decision.input
    }

    state |> cancel(key) |> put_entry(key, Map.put(entry, :clarification, clarification))
  end

  def reject_clarification(state, decision, command_id) do
    key = key(decision)

    case entry(state, key) do
      %{clarification: %{command_id: ^command_id}} = entry ->
        put_entry(state, key, Map.delete(entry, :clarification))

      _other ->
        state
    end
  end

  def clarification_current?(state, decision, command_id) do
    target_current? =
      if decision.task_id == nil,
        do: match?(%{status: :pending}, entry(state, key(decision))),
        else:
          State.current_result?(state, %{
            task_id: decision.task_id,
            task_revision: decision.expected_task_revision,
            provider_generation: state.context.provider_generation
          })

    delegation_current? =
      decision.delegation_id == nil or
        match?(%{status: :pending}, state.context.pending_delegations[decision.delegation_id])

    target_current? and delegation_current? and
      match?(%{clarification: %{command_id: ^command_id}}, entry(state, key(decision)))
  end

  defp entry(state, {:delegation, id}), do: state.context.pending_delegations[id]
  defp entry(state, {:task, id, _revision}), do: state.context.tasks[id]

  defp put_entry(state, {:delegation, id}, entry) do
    context = state.context
    State.revise(state, put_in(context.pending_delegations[id], entry))
  end

  defp put_entry(state, {:task, id, _revision}, entry) do
    context = state.context
    State.revise(state, put_in(context.tasks[id], entry))
  end

  defp trigger({:delegation, id}),
    do: %ContextTrigger{kind: :context_wait_expired, delegation_id: id}

  defp trigger({:task, id, _revision}),
    do: %ContextTrigger{kind: :context_wait_expired, task_id: id}
end
