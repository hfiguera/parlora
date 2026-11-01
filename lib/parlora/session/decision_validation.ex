defmodule Parlora.Session.DecisionValidation do
  @moduledoc false
  alias Parlora.{ContextDecision, Error}
  alias Parlora.Session.ContextWait

  def validate(state, decisions) when is_list(decisions) do
    with :ok <- validate_shapes(decisions), do: validate_batch(state, decisions)
  end

  def validate(_state, _decisions),
    do: Error.tuple(:invalid_argument, "Policy must return decisions")

  defp validate_shapes(decisions) do
    if Enum.all?(decisions, &match?(%ContextDecision{}, &1)),
      do: :ok,
      else: Error.tuple(:invalid_argument, "Policy returned a malformed decision")
  end

  defp validate_batch(state, decisions) do
    targets = Enum.flat_map(decisions, &targets/1)
    starts = Enum.count(decisions, &(&1.kind in [:start_task, :supersede_task]))

    active =
      Enum.count(state.jobs, fn {_id, job} ->
        job.status not in [:completed, :failed, :cancelled]
      end)

    cond do
      length(targets) != MapSet.size(MapSet.new(targets)) ->
        Error.tuple(:invalid_argument, "Conflicting decisions in policy batch")

      association_conflicts?(decisions) ->
        Error.tuple(:invalid_argument, "Cannot associate a delegation while revising its task")

      active + starts > state.limits.max_jobs + state.limits.max_pending_jobs ->
        Error.tuple(:backpressure, "Backend job capacity exhausted, including superseded work")

      clarification_count(state, decisions) > state.limits.max_records ->
        Error.tuple(:backpressure, "Clarification record capacity exhausted")

      map_size(state.jobs) + starts > state.limits.max_records ->
        Error.tuple(:backpressure, "Session record capacity exhausted")

      true ->
        validate_decisions(state, decisions)
    end
  end

  defp clarification_count(state, decisions) do
    decisions
    |> Enum.filter(&(&1.kind == :request_clarification))
    |> Enum.reduce(state.clarifications, &MapSet.put(&2, ContextWait.clarification_key(&1)))
    |> MapSet.size()
  end

  defp association_conflicts?(decisions) do
    revisions =
      decisions
      |> Enum.filter(&(&1.kind in [:update_task, :supersede_task]))
      |> MapSet.new(& &1.task_id)

    Enum.any?(
      decisions,
      &(&1.kind == :associate_delegation and MapSet.member?(revisions, &1.task_id))
    )
  end

  defp validate_decisions(state, decisions) do
    Enum.reduce_while(decisions, :ok, fn decision, :ok ->
      with :ok <- validate_reference(decision),
           :ok <- validate_decision(state, decision) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_reference(%ContextDecision{
         kind: :start_task,
         task_id: id,
         expected_task_revision: revision
       })
       when not is_nil(id) or not is_nil(revision),
       do:
         Error.tuple(
           :invalid_argument,
           "start_task uses delegation_id or anchor_task_id with expected_anchor_revision"
         )

  defp validate_reference(%ContextDecision{anchor_task_id: nil, expected_anchor_revision: nil}),
    do: :ok

  defp validate_reference(%ContextDecision{
         kind: :start_task,
         delegation_id: nil,
         anchor_task_id: id,
         expected_anchor_revision: revision
       })
       when is_binary(id) and is_integer(revision) and revision > 0,
       do: :ok

  defp validate_reference(%ContextDecision{kind: :start_task}),
    do:
      Error.tuple(
        :invalid_argument,
        "Follow-up requires a complete anchor and no delegation: anchor_task_id and positive expected_anchor_revision"
      )

  defp validate_reference(_decision),
    do: Error.tuple(:invalid_argument, "Anchor fields are only valid for start_task")

  defp target(%ContextDecision{kind: :no_action}), do: nil

  defp target(%ContextDecision{kind: :associate_delegation, delegation_id: id}),
    do: {:delegation, id}

  defp target(%ContextDecision{kind: :start_task, anchor_task_id: id}) when is_binary(id),
    do: {:task, id}

  defp target(%ContextDecision{task_id: id}) when is_binary(id), do: {:task, id}
  defp target(%ContextDecision{delegation_id: id}) when is_binary(id), do: {:delegation, id}
  defp target(_decision), do: nil

  defp targets(%ContextDecision{kind: kind, task_id: task, delegation_id: call})
       when kind in [:request_clarification, :supersede_task] and is_binary(task) and
              is_binary(call),
       do: [{:task, task}, {:delegation, call}]

  defp targets(decision), do: List.wrap(target(decision))

  defp validate_decision(_state, %ContextDecision{kind: :no_action}), do: :ok

  defp validate_decision(state, %ContextDecision{kind: :associate_delegation} = decision) do
    with %{status: :pending} <- state.context.pending_delegations[decision.delegation_id],
         %{revision: revision} <- state.context.tasks[decision.task_id],
         true <- revision == decision.expected_task_revision do
      :ok
    else
      _invalid ->
        Error.tuple(
          :invalid_argument,
          "Association requires a pending delegation and current task revision"
        )
    end
  end

  defp validate_decision(
         state,
         %ContextDecision{kind: :start_task, anchor_task_id: id} = decision
       )
       when is_binary(id) do
    case state.context.tasks[id] do
      %{revision: revision} when revision == decision.expected_anchor_revision ->
        validate_content(decision)

      _missing_or_stale ->
        Error.tuple(
          :invalid_argument,
          "Follow-up requires an existing anchor at expected_anchor_revision"
        )
    end
  end

  defp validate_decision(state, %ContextDecision{kind: kind, task_id: nil} = decision)
       when kind in [:start_task, :wait_for_context, :request_clarification] do
    case state.context.pending_delegations[decision.delegation_id] do
      %{status: :pending} ->
        validate_content(decision)

      _missing_or_claimed ->
        Error.tuple(:invalid_argument, "Decision requires a pending delegation")
    end
  end

  defp validate_decision(state, %ContextDecision{kind: kind} = decision)
       when kind in [:update_task, :supersede_task, :request_clarification, :wait_for_context] do
    with %{revision: revision} <- state.context.tasks[decision.task_id],
         true <- revision == decision.expected_task_revision,
         :ok <- validate_task_delegation(state, decision),
         :ok <- validate_update_capability(state, kind) do
      validate_content(decision)
    else
      {:error, _error} = error -> error
      _stale -> Error.tuple(:invalid_argument, "Decision targets a missing or stale task")
    end
  end

  defp validate_decision(_state, _decision),
    do: Error.tuple(:invalid_argument, "Unsupported context decision")

  defp validate_task_delegation(state, %ContextDecision{
         kind: kind,
         delegation_id: id
       })
       when kind in [:request_clarification, :supersede_task] and not is_nil(id) do
    case state.context.pending_delegations[id] do
      %{status: :pending} -> :ok
      _ -> Error.tuple(:invalid_argument, "Task decision requires a pending delegation")
    end
  end

  defp validate_task_delegation(_state, _decision), do: :ok

  defp validate_update_capability(state, :update_task) do
    if state.ready.backend.updates?,
      do: :ok,
      else: Error.tuple(:unsupported, "Backend cannot update work")
  end

  defp validate_update_capability(_state, _kind), do: :ok

  defp validate_content(%ContextDecision{
         kind: :request_clarification,
         message: message,
         clarification_key: key,
         input: input
       })
       when is_binary(message) and byte_size(message) > 0 and
              (is_nil(key) or (is_binary(key) and byte_size(key) in 1..128)),
       do: validate_clarification_input(input)

  defp validate_content(%ContextDecision{kind: :request_clarification}),
    do:
      Error.tuple(
        :invalid_argument,
        "Clarification requires a question and an optional 1–128 byte key"
      )

  defp validate_content(%ContextDecision{
         kind: :wait_for_context,
         recheck_after_ms: delay,
         recheck_key: key
       })
       when (is_nil(delay) or (is_integer(delay) and delay > 0 and delay <= 60_000)) and
              (is_nil(key) or (is_binary(key) and byte_size(key) in 1..128)),
       do: :ok

  defp validate_content(%ContextDecision{kind: :wait_for_context}),
    do:
      Error.tuple(
        :invalid_argument,
        "Context recheck requires 1–60000 ms and an optional 1–128 byte key"
      )

  defp validate_content(%ContextDecision{input: input}) when is_map(input), do: :ok
  defp validate_content(_decision), do: Error.tuple(:invalid_argument, "Task input must be a map")

  defp validate_clarification_input(input) do
    if is_map(input) and :erlang.external_size(input) <= 4_096,
      do: :ok,
      else:
        Error.tuple(
          :invalid_argument,
          "Clarification input must be a map of at most 4096 encoded bytes"
        )
  end
end
