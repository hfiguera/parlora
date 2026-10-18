defmodule Parlora.Session.Decisions do
  @moduledoc false
  alias Parlora.{BackendRequest, ContextDecision, ContextUpdate, Error, ID}
  alias Parlora.Session.{Commands, ContextWait, State, Uncertainty}

  def apply_batch(state, decisions) when is_list(decisions) do
    with :ok <- validate_shapes(decisions),
         :ok <- validate_batch(state, decisions) do
      {:ok, Enum.reduce(decisions, state, &apply_decision/2)}
    end
  end

  def apply_batch(_state, _decisions),
    do: Error.tuple(:invalid_argument, "Policy must return decisions")

  defp validate_shapes(decisions) do
    if Enum.all?(decisions, &match?(%ContextDecision{}, &1)),
      do: :ok,
      else: Error.tuple(:invalid_argument, "Policy returned a malformed decision")
  end

  def dispatch_pending(%{status: :ready} = state) do
    queued =
      state.jobs
      |> Enum.filter(fn {_id, job} -> job.status == :queued end)
      |> Enum.sort_by(fn {_id, job} -> job.request.deadline_at_us end)

    Enum.reduce_while(queued, state, fn {_id, job}, acc ->
      if active_count(acc) < acc.limits.max_jobs,
        do: {:cont, dispatch(acc, job.request)},
        else: {:halt, acc}
    end)
  end

  def dispatch_pending(state), do: state

  def resolve_delegation(state, nil, _outcome), do: state

  def resolve_delegation(state, id, outcome) do
    {module, pid} = state.adapters.provider

    if function_exported?(module, :resolve_delegation, 3) do
      entry = state.context.pending_delegations[id]
      generation = state.context.provider_generation

      Commands.run(
        state,
        :provider,
        {:current,
         fn current ->
           fresh = resolution_outcome(current, entry, outcome)
           fn -> module.resolve_delegation(pid, id, fresh) end
         end},
        fn current, _reply -> current end,
        guard: fn current ->
          current.context.provider_generation == generation and
            not match?(%{status: :cancelled}, current.context.pending_delegations[id]) and
            resolution_current?(current, id, entry, outcome)
        end
      )
    else
      state
    end
  end

  defp resolution_current?(state, id, _entry, %{status: :superseded}) do
    not Enum.any?(state.jobs, fn {_id, job} ->
      job.request.delegation_id == id and State.current_result?(state, job.request)
    end)
  end

  defp resolution_current?(state, _id, %{task_id: task, task_revision: revision}, _outcome) do
    State.current_result?(state, %{
      task_id: task,
      task_revision: revision,
      provider_generation: state.context.provider_generation
    })
  end

  defp resolution_current?(_state, _id, _entry, _outcome), do: true

  defp resolution_outcome(state, %{task_id: task_id}, %{status: :associated}) do
    task = state.context.tasks[task_id]
    latest = task.request_ids |> List.first() |> then(&state.jobs[&1])

    summary =
      case latest do
        %{status: :uncertain} -> Uncertainty.message()
        %{result: %{summary: summary}} -> summary
        _pending -> nil
      end

    %{
      status: :associated,
      task_status: task.status,
      result_delivery: if(latest, do: Map.get(latest, :delivery, latest[:uncertainty_delivery])),
      result:
        summary ||
          "This request is already tracked; wait for a verified application update. Do not repeat the work."
    }
  end

  defp resolution_outcome(_state, _entry, outcome), do: outcome

  defp active_count(state) do
    Enum.count(state.jobs, fn {_id, job} -> job.status in [:submitted, :uncertain] end)
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
    |> Enum.reduce(state.clarifications, &MapSet.put(&2, clarification_key(&1)))
    |> MapSet.size()
  end

  defp clarification_key(decision),
    do:
      {decision.delegation_id, decision.task_id, decision.expected_task_revision,
       decision.clarification_key}

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
           :ok <- validate(state, decision) do
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

  defp validate(_state, %ContextDecision{kind: :no_action}), do: :ok

  defp validate(state, %ContextDecision{kind: :associate_delegation} = decision) do
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

  defp validate(state, %ContextDecision{kind: :start_task, anchor_task_id: id} = decision)
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

  defp validate(state, %ContextDecision{kind: kind, task_id: nil} = decision)
       when kind in [:start_task, :wait_for_context, :request_clarification] do
    case state.context.pending_delegations[decision.delegation_id] do
      %{status: :pending} ->
        validate_content(decision)

      _missing_or_claimed ->
        Error.tuple(:invalid_argument, "Decision requires a pending delegation")
    end
  end

  defp validate(state, %ContextDecision{kind: kind} = decision)
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

  defp validate(_state, _decision),
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

  defp apply_decision(%ContextDecision{kind: :no_action}, state), do: state

  defp apply_decision(%ContextDecision{kind: :associate_delegation} = decision, state) do
    state = claim(state, decision.delegation_id)
    context = state.context

    entry =
      Map.merge(context.pending_delegations[decision.delegation_id], %{
        task_id: decision.task_id,
        task_revision: decision.expected_task_revision
      })

    state =
      State.revise(state, put_in(context.pending_delegations[decision.delegation_id], entry))

    State.emit(state, :delegation_associated, Map.take(entry, [:id, :task_id, :task_revision]))
    resolve_delegation(state, decision.delegation_id, %{status: :associated})
  end

  defp apply_decision(%ContextDecision{kind: :wait_for_context} = decision, state),
    do: ContextWait.schedule(state, decision)

  defp apply_decision(%ContextDecision{kind: :request_clarification} = decision, state),
    do: clarify(state, decision)

  defp apply_decision(%ContextDecision{kind: :start_task} = decision, state) do
    task = %{
      id: ID.new(),
      revision: 1,
      input: decision.input,
      status: :submitted,
      request_ids: [],
      delegation_id: decision.delegation_id,
      confirmation: nil
    }

    state = claim(state, decision.delegation_id)
    state = bind_delegation(state, decision.delegation_id, task)
    submit(state, task)
  end

  defp apply_decision(%ContextDecision{kind: :supersede_task} = decision, state) do
    old = state.context.tasks[decision.task_id]

    task = %{
      old
      | revision: old.revision + 1,
        input: decision.input,
        confirmation: nil,
        delegation_id: decision.delegation_id || old.delegation_id,
        status: :submitted
    }

    state = claim(state, decision.delegation_id)
    state = bind_delegation(state, decision.delegation_id, task)

    if decision.delegation_id,
      do:
        State.emit(state, :delegation_associated, %{
          id: decision.delegation_id,
          task_id: task.id,
          task_revision: task.revision
        })

    submit(state, task)
  end

  defp apply_decision(%ContextDecision{kind: :update_task} = decision, state) do
    state = ContextWait.cancel(state, ContextWait.key(decision))
    old = state.context.tasks[decision.task_id]
    [request_id | _older] = old.request_ids

    task =
      %{old | revision: old.revision + 1, input: decision.input, confirmation: nil}
      |> Map.drop([:context_wait, :clarification])

    request = request(state, task, request_id)
    {module, pid} = state.adapters.backend
    command_id = ID.new()
    state = put_task(state, task)
    job = state.jobs[request_id]

    pending = %{command_id: command_id, request: request}

    state = %{
      state
      | jobs: Map.put(state.jobs, request_id, Map.put(job, :pending_update, pending))
    }

    Commands.run(
      state,
      :backend,
      fn -> module.update(pid, command_id, request_id, request) end,
      &update_result(&1, task.id, request_id, command_id, &2),
      guard: &State.current_result?(&1, request),
      deadline: request.deadline_at_us
    )
  end

  defp update_result(state, _task, _request, _command, :ok), do: state

  defp update_result(state, task, request, command, {:error, error}) do
    uncertain? = error.code == :timeout or error.details[:outcome] == :unknown

    State.emit(
      state,
      if(uncertain?, do: :update_uncertain, else: :admission_rejected),
      %{error: error, task_id: task},
      command_id: command,
      request_id: request
    )

    if uncertain? or not match?(%{pending_update: %{command_id: ^command}}, state.jobs[request]),
      do: state,
      else: %{state | jobs: Map.update!(state.jobs, request, &Map.delete(&1, :pending_update))}
  end

  defp submit(state, task) do
    state = ContextWait.cancel(state, {:task, task.id, task.revision - 1})
    task = Map.drop(task, [:context_wait, :clarification])
    id = ID.new()
    request = request(state, task, id)
    Process.send_after(self(), {:job_deadline, id}, state.limits.job_timeout_ms)
    task = %{task | request_ids: [id | task.request_ids]}
    state = put_task(state, task)

    if active_count(state) < state.limits.max_jobs do
      dispatch(state, request)
    else
      State.emit(state, :task_queued, %{task_id: task.id, task_revision: task.revision},
        request_id: id
      )

      %{state | jobs: Map.put(state.jobs, id, %{request: request, status: :queued})}
    end
  end

  defp dispatch(state, request) do
    if request.deadline_at_us <= System.monotonic_time(:microsecond) do
      State.emit(
        state,
        :admission_rejected,
        %{error: Error.new(:timeout, "Queued job expired before submission")},
        request_id: request.id
      )

      %{state | jobs: Map.put(state.jobs, request.id, %{request: request, status: :failed})}
    else
      dispatch_current(state, request)
    end
  end

  defp dispatch_current(state, request) do
    if State.current_result?(state, request) do
      {module, pid} = state.adapters.backend

      state = %{
        state
        | jobs:
            Map.put(state.jobs, request.id, %{
              request: request,
              status: :submitted,
              admission: :pending
            })
      }

      Commands.run(
        state,
        :backend,
        fn -> module.submit(pid, request) end,
        &submission_result(&1, request, &2),
        guard: &submission_current?(&1, request),
        deadline: request.deadline_at_us,
        key: {:submit, request.id},
        start: &submission_started(&1, request.id)
      )
    else
      %{state | jobs: Map.put(state.jobs, request.id, %{request: request, status: :cancelled})}
    end
  end

  defp submission_current?(state, request) do
    State.current_result?(state, request) and
      state.jobs[request.id].status in [:submitted, :uncertain]
  end

  defp submission_started(state, id) do
    %{state | jobs: Map.update!(state.jobs, id, &Map.put(&1, :admission, :started))}
  end

  defp submission_result(state, request, reply) do
    state = %{
      state
      | jobs: Map.update!(state.jobs, request.id, &Map.put(&1, :admission, :settled))
    }

    State.emit(state, :task_submitted, %{request: request, admission: reply},
      request_id: request.id
    )

    case {state.jobs[request.id], reply} do
      {_, :ok} ->
        state

      {%{status: status} = job, {:error, error}} when status in [:submitted, :uncertain] ->
        cond do
          error.details[:execution] == :never_submitted ->
            %{state | jobs: Map.put(state.jobs, request.id, %{job | status: :cancelled})}

          error.code == :timeout or error.details[:outcome] == :unknown ->
            Uncertainty.mark(state, request.id, :unknown)

          true ->
            state = %{state | jobs: Map.put(state.jobs, request.id, %{job | status: :failed})}

            resolve_delegation(state, request.delegation_id, %{
              status: :failed,
              result: "Backend rejected the request; no successful result is available."
            })
        end

      _terminal ->
        state
    end
  end

  defp request(state, task, id) do
    %BackendRequest{
      id: id,
      task_id: task.id,
      task_revision: task.revision,
      provider_generation: state.context.provider_generation,
      delegation_id: task.delegation_id,
      input: task.input,
      context: state.context,
      deadline_at_us: System.monotonic_time(:microsecond) + state.limits.job_timeout_ms * 1_000
    }
  end

  defp bind_delegation(state, nil, _task), do: state

  defp bind_delegation(state, id, task) do
    entry =
      Map.merge(state.context.pending_delegations[id], %{
        task_id: task.id,
        task_revision: task.revision
      })

    context = %{
      state.context
      | pending_delegations: Map.put(state.context.pending_delegations, id, entry)
    }

    State.revise(state, context)
  end

  defp claim(state, nil), do: state

  defp claim(state, id) do
    state = ContextWait.cancel(state, {:delegation, id})
    context = state.context

    context =
      update_in(context.pending_delegations[id], fn entry ->
        entry |> Map.put(:status, :claimed) |> Map.delete(:context_wait)
      end)

    State.revise(state, context)
  end

  defp put_task(state, task) do
    State.revise(state, %{state.context | tasks: Map.put(state.context.tasks, task.id, task)})
  end

  # Re-evaluate against fresh captions instead of queueing a question which may
  # already have been answered by the time the provider finishes speaking.
  defp clarify(%{provider_speech: :speaking} = state, decision) do
    ContextWait.schedule(state, %{
      decision
      | recheck_after_ms: 500,
        recheck_key: "speech:#{state.context.revision}"
    })
  end

  defp clarify(state, decision) do
    key = clarification_key(decision)

    if MapSet.member?(state.clarifications, key) do
      state
    else
      update = %ContextUpdate{
        id: ID.new(),
        kind: :speakable,
        content: decision.message,
        delegation_id: decision.delegation_id,
        provider_generation: state.context.provider_generation,
        task_id: decision.task_id,
        task_revision: decision.expected_task_revision
      }

      {module, pid} = state.adapters.provider
      state = ContextWait.clarify(state, decision, update.id)
      state = %{state | clarifications: MapSet.put(state.clarifications, key)}
      revision = state.context.revision

      Commands.run(
        state,
        :provider,
        fn -> module.append_context(pid, update) end,
        &clarification_result(&1, decision, update.id, key, &2),
        guard: fn current ->
          current.context.revision == revision and
            current.context.provider_generation == update.provider_generation and
            current.policy_task == nil and
            current.provider_speech != :speaking and
            ContextWait.clarification_current?(current, decision, update.id)
        end
      )
    end
  end

  defp clarification_result(state, decision, command, _key, :ok) do
    State.emit(
      state,
      :clarification_requested,
      %{
        delegation_id: decision.delegation_id,
        task_id: decision.task_id,
        task_revision: decision.expected_task_revision
      },
      command_id: command
    )

    state
  end

  defp clarification_result(state, decision, command, key, {:error, error}) do
    State.emit(state, :context_rejected, %{error: error}, command_id: command)

    recheck? =
      state.status == :ready and error.code == :invalid_argument and
        error.details[:execution] == :never_submitted and
        ContextWait.clarification_current?(state, decision, command)

    state = ContextWait.reject_clarification(state, decision, command)
    state = %{state | clarifications: MapSet.delete(state.clarifications, key)}

    if recheck?,
      do:
        ContextWait.schedule(state, %{
          decision
          | recheck_after_ms: 1,
            recheck_key: command
        }),
      else: state
  end

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
