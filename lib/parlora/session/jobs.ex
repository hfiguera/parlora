defmodule Parlora.Session.Jobs do
  @moduledoc false
  alias Parlora.{BackendResult, ContextUpdate, Error, ID, Telemetry}
  alias Parlora.Session.{Commands, Decisions, Progress, State, Uncertainty}

  def cancel(state, id, request_id, reason, from) do
    case state.cancellations[id] do
      {^request_id, ^reason} ->
        {:reply, :ok, state}

      nil ->
        case state.jobs[request_id] do
          nil -> {:reply, Error.tuple(:invalid_argument, "Unknown request"), state}
          job -> cancel_job(state, job, id, request_id, reason, from)
        end

      _conflict ->
        {:reply, Error.tuple(:invalid_argument, "Conflicting cancellation ID"), state}
    end
  end

  def cancel_delegation(state, id),
    do: Enum.reduce(state.jobs, state, &cancel_delegated_job(&1, &2, id))

  def cancellation_deadline(state, id, request_id) do
    case state.jobs[request_id] do
      %{status: status} when status in [:completed, :failed, :cancelled] ->
        :ok

      _pending ->
        State.emit(state, :cancellation_unconfirmed, %{outcome: :unknown},
          command_id: id,
          request_id: request_id
        )
    end

    state
  end

  def deadline(state, id) do
    case state.jobs[id] do
      %{status: status, request: request} = job
      when status == :queued or
             (status == :submitted and :erlang.map_get(:admission, job) == :pending) ->
        result = %BackendResult{
          request_id: id,
          task_id: request.task_id,
          task_revision: request.task_revision,
          provider_generation: request.provider_generation,
          status: :failed,
          error: Error.new(:timeout, "Queued job expired before submission"),
          metadata: %{execution: :never_submitted}
        }

        State.emit(state, :request_failed, result, request_id: id)
        complete(state, result) |> Commands.cancel({:submit, id})

      %{status: :submitted} ->
        State.emit(
          state,
          :request_uncertain,
          %{
            error: Error.new(:timeout, "Job deadline expired; work may still run"),
            reason: :job_deadline
          },
          request_id: id
        )

        Uncertainty.mark(state, id, :job_deadline) |> deliver_pending()

      _terminal_or_unknown ->
        state
    end
  end

  defp cancel_job(state, job, id, request_id, reason, from \\ nil)

  defp cancel_job(state, %{status: status}, _id, _request_id, _reason, _from)
       when status in [:completed, :failed, :cancelled],
       do:
         {:reply, Error.tuple(:invalid_argument, "Request already has a terminal outcome"), state}

  defp cancel_job(state, _job, id, request_id, reason, from) do
    case state.cancellations[id] do
      {^request_id, ^reason} -> {:reply, :ok, state}
      nil -> request_cancel(state, id, request_id, reason, from)
      _conflict -> {:reply, Error.tuple(:invalid_argument, "Conflicting cancellation ID"), state}
    end
  end

  defp request_cancel(state, id, request_id, reason, from) do
    pending? = Map.has_key?(state.commands.keys, {:cancel, id})

    pending =
      Enum.count(state.commands.keys, fn
        {{:cancel, _id}, _reference} -> true
        _other -> false
      end)

    if pending? or map_size(state.cancellations) + pending < state.limits.max_records do
      admit_cancel(state, id, request_id, reason, from)
    else
      {:reply, Error.tuple(:backpressure, "Cancellation record capacity exhausted"), state}
    end
  end

  defp admit_cancel(state, id, request_id, reason, from) do
    job = state.jobs[request_id]

    if job.status == :queued or Map.get(job, :admission) == :pending do
      job = state.jobs[request_id]

      result = %BackendResult{
        request_id: request_id,
        task_id: job.request.task_id,
        task_revision: job.request.task_revision,
        provider_generation: job.request.provider_generation,
        status: :cancelled,
        metadata: %{execution: :never_submitted}
      }

      State.emit(state, :request_cancelled, result,
        command_id: id,
        request_id: request_id
      )

      state = complete(state, result) |> Commands.cancel({:submit, request_id})

      {:reply, :ok,
       %{state | cancellations: Map.put(state.cancellations, id, {request_id, reason})}}
    else
      cancel_running(state, id, request_id, reason, from)
    end
  end

  defp cancel_running(state, id, request_id, reason, from) do
    {module, pid} = state.adapters.backend

    complete = fn current, reply ->
      if reply == :ok do
        Process.send_after(
          self(),
          {:cancellation_deadline, id, request_id},
          current.limits.cancellation_timeout_ms
        )

        %{current | cancellations: Map.put(current.cancellations, id, {request_id, reason})}
      else
        current
      end
    end

    guard = fn current ->
      match?(%{status: status} when status in [:submitted, :uncertain], current.jobs[request_id])
    end

    case Commands.enqueue(
           state,
           :backend,
           fn -> module.cancel(pid, id, request_id, reason) end,
           complete,
           from: from,
           key: {:cancel, id},
           signature: {request_id, reason},
           guard: guard
         ) do
      {:ok, next} -> if(from == nil, do: {:reply, :ok, next}, else: {:noreply, next})
      error -> {:reply, error, state}
    end
  end

  def complete(state, result) do
    case state.jobs[result.request_id] do
      %{request: request, status: status} = job
      when status not in [:completed, :failed, :cancelled] ->
        if request.task_id == result.task_id and request.task_revision == result.task_revision and
             request.provider_generation == result.provider_generation do
          now = System.monotonic_time(:microsecond)

          job =
            job
            |> Telemetry.finish(:telemetry_queue, result.status)
            |> Telemetry.finish(:telemetry_backend, result.status)

          delivery = delivery_telemetry(state, request)

          job =
            Map.merge(job, %{
              telemetry_delivery: delivery,
              status: result.status,
              result: result,
              delivery: :pending,
              completed_at_us: now,
              delivery_updated_at_us: now
            })
            |> Uncertainty.clear_pending()

          state = %{state | jobs: Map.put(state.jobs, result.request_id, job)}

          State.emit(state, :result_delivery, %{stage: :awaiting_interpretation},
            request_id: result.request_id
          )

          deliver_pending(state) |> Decisions.dispatch_pending()
        else
          state
        end

      _duplicate_or_unknown ->
        state
    end
  end

  defp delivery_telemetry(%{status: :ready} = state, request),
    do: Telemetry.start(:delivery, Telemetry.request(state, request))

  defp delivery_telemetry(_state, _request), do: nil

  def deliver_pending(
        %{context_resolved?: true, policy_task: nil, status: :ready, output_recovery: nil} =
          state
      ) do
    Enum.reduce(state.jobs, state, fn
      {id, %{delivery: :pending} = job}, acc ->
        acc = %{acc | jobs: Map.put(acc.jobs, id, %{job | delivery: :done})}
        deliver_result(acc, job.request, job.result)

      {_id, %{status: :uncertain, uncertainty_delivery: :pending} = job}, acc ->
        Uncertainty.deliver(acc, job.request, State.current_delivery?(acc, job.request))

      _other, acc ->
        acc
    end)
  end

  def deliver_pending(state), do: state

  defp deliver_result(state, request, result) do
    if State.current_delivery?(state, request) and state.status == :ready do
      task = %{state.context.tasks[result.task_id] | status: result.status}

      state =
        State.revise(state, %{state.context | tasks: Map.put(state.context.tasks, task.id, task)})

      append_result(state, request, result)
    else
      State.emit(state, :stale_result, %{result: result}, request_id: result.request_id)

      state =
        if delegation_in_use?(state, request) do
          state
        else
          Decisions.resolve_delegation(state, request.delegation_id, %{
            status: :superseded,
            instruction: "Do not announce the obsolete result."
          })
        end

      Progress.delivery(state, request, :stale)
    end
  end

  # A replacement revision may inherit the same provider call before a new
  # delegation arrives. Discarding an old result must not close its current route.
  defp delegation_in_use?(state, request) do
    Enum.any?(state.jobs, fn {id, job} ->
      id != request.id and job.request.delegation_id == request.delegation_id and
        State.current_delivery?(state, job.request)
    end)
  end

  defp append_result(state, request, %BackendResult{summary: summary} = result)
       when is_binary(summary) do
    update = %ContextUpdate{
      id: ID.new(),
      kind: :speakable,
      content: summary,
      delegation_id: delivery_delegation(state, request),
      provider_generation: result.provider_generation,
      task_id: result.task_id,
      task_revision: result.task_revision
    }

    {module, pid} = state.adapters.provider

    state = Progress.delivery(state, request, :awaiting_provider, update.id)

    Commands.run(
      state,
      :provider,
      fn -> module.append_context(pid, update) end,
      &result_admission(&1, request, update.id, &2),
      guard: &State.current_delivery?(&1, request)
    )
  end

  defp append_result(state, request, result) do
    state =
      Decisions.resolve_delegation(state, request.delegation_id, %{
        status: result.status,
        result: "No speakable result is available."
      })

    Progress.delivery(state, request, :not_applicable)
  end

  defp result_admission(state, _request, _command, :ok), do: state

  defp result_admission(state, request, command, {:error, error}) do
    State.emit(state, :context_rejected, %{error: error}, command_id: command)
    job = state.jobs[request.id]

    if job.result_command_id == command and job.delivery == :awaiting_provider do
      Progress.delivery(
        state,
        request,
        State.delivery_error_stage(state, request, error),
        command
      )
    else
      state
    end
  end

  defp cancel_delegated_job({request_id, job}, state, delegation_id) do
    if job.request.delegation_id == delegation_id and State.cancelled_result?(state, job.request) and
         job.status in [:queued, :submitted, :uncertain] do
      {:reply, _reply, next} = cancel_job(state, job, ID.new(), request_id, :provider_cancelled)
      next
    else
      state
    end
  end

  defp delivery_delegation(state, request) do
    case state.context.pending_delegations[request.delegation_id] do
      %{status: :cancelled} -> nil
      _active -> request.delegation_id
    end
  end
end
