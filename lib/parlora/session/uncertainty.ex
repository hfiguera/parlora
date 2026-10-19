defmodule Parlora.Session.Uncertainty do
  @moduledoc false
  alias Parlora.{ContextUpdate, ID}
  alias Parlora.Session.{Commands, State}

  @reasons ~w(framework_failure structured_completion_missing execution_exception execution_exit observer_exited execution_deadline cancellation_requested session_closed shutdown_deadline invalid_result job_deadline)a

  def reason(value) when value in @reasons, do: value
  def reason(_value), do: :unknown

  def clear_pending(%{uncertainty_delivery: :pending} = job),
    do: %{job | uncertainty_delivery: :superseded}

  def clear_pending(job), do: job

  def message do
    "No verified result is available for this request. Tell the caller you couldn't confirm the outcome and ask what they would like to do next. " <>
      "Do not promise the work is still running. Do not claim any external action completed, was cancelled or was reversed. Do not retry automatically."
  end

  def mark(state, id, cause) do
    case state.jobs[id] do
      %{uncertainty_delivery: _delivery} ->
        state

      %{status: status} = job when status in [:submitted, :uncertain] ->
        mark_job(state, id, job, cause)

      _other ->
        state
    end
  end

  defp mark_job(state, id, job, cause) do
    job =
      job
      |> Parlora.Telemetry.finish(:telemetry_queue, :uncertain)
      |> Parlora.Telemetry.finish(:telemetry_backend, :uncertain)

    job =
      Map.merge(job, %{
        status: :uncertain,
        uncertainty_reason: reason(cause),
        uncertainty_delivery: :pending
      })

    state = %{state | jobs: Map.put(state.jobs, id, job)}

    if State.current_result?(state, job.request) do
      task = %{state.context.tasks[job.request.task_id] | status: :uncertain}
      State.revise(state, %{state.context | tasks: Map.put(state.context.tasks, task.id, task)})
    else
      state
    end
  end

  def deliver(state, request, current?) do
    if current? do
      update = %ContextUpdate{
        id: ID.new(),
        kind: :speakable,
        content: message(),
        delegation_id: request.delegation_id,
        provider_generation: request.provider_generation,
        task_id: request.task_id,
        task_revision: request.task_revision
      }

      {module, pid} = state.adapters.provider

      state = put_delivery(state, request.id, :awaiting_provider, update.id)

      Commands.run(
        state,
        :provider,
        fn -> module.append_context(pid, update) end,
        &delivery_result(&1, request, update.id, &2),
        guard: &pending_delivery?(&1, request, update.id)
      )
    else
      put_delivery(state, request.id, :stale, nil)
    end
  end

  defp pending_delivery?(state, request, command) do
    case state.jobs[request.id] do
      %{
        status: :uncertain,
        uncertainty_command_id: ^command,
        uncertainty_delivery: :awaiting_provider
      } ->
        State.current_delivery?(state, request)

      _superseded ->
        false
    end
  end

  defp delivery_result(state, _request, _command, :ok), do: state

  defp delivery_result(state, request, command, {:error, error}) do
    job = state.jobs[request.id]

    if job.uncertainty_command_id == command and job.uncertainty_delivery == :awaiting_provider,
      do:
        put_delivery(
          state,
          request.id,
          rejection_stage(state, request, error),
          command
        ),
      else: state
  end

  defp rejection_stage(state, request, error) do
    if error.details[:execution] == :never_submitted and
         state.jobs[request.id].status in [:completed, :failed, :cancelled],
       do: :superseded,
       else: State.delivery_error_stage(state, request, error)
  end

  def acknowledge(state, command_id, stage) do
    Enum.reduce(state.jobs, state, fn
      {id, %{uncertainty_command_id: ^command_id, uncertainty_delivery: delivery}}, acc
      when delivery in [:awaiting_provider, :unconfirmed, :unknown] ->
        put_delivery(acc, id, stage, command_id)

      _other, acc ->
        acc
    end)
  end

  defp put_delivery(state, id, stage, command_id) do
    job =
      Map.merge(state.jobs[id], %{uncertainty_delivery: stage, uncertainty_command_id: command_id})

    %{state | jobs: Map.put(state.jobs, id, job)}
  end
end
