defmodule Parlora.Session.Progress do
  @moduledoc false
  alias Parlora.Session.Health
  alias Parlora.Session.State
  alias Parlora.Session.Uncertainty

  def snapshot(state) do
    %{
      session_id: state.id,
      status: state.status,
      provider_activity: state.provider_activity,
      provider_speech: state.provider_speech,
      context_acknowledgment?:
        Map.get(Map.get(state.ready, :provider, %{}), :context_acknowledgment?, false),
      observed_at_us: System.monotonic_time(:microsecond),
      interpretation: interpretation(state),
      delegations:
        Map.new(state.context.pending_delegations, fn {id, entry} ->
          {id,
           Map.take(entry, [
             :status,
             :admission,
             :received_at_us,
             :context_wait,
             :clarification,
             :task_id,
             :task_revision
           ])}
        end),
      jobs:
        Map.new(state.jobs, fn {id, job} ->
          details =
            Map.take(job, [
              :status,
              :started_at_us,
              :completed_at_us,
              :delivery,
              :result_command_id,
              :delivery_updated_at_us,
              :uncertainty_reason,
              :uncertainty_delivery
            ])

          details =
            if Map.get(details, :delivery) == :pending,
              do: %{details | delivery: :awaiting_interpretation},
              else: details

          identity =
            Map.take(job.request, [:task_id, :task_revision, :delegation_id, :deadline_at_us])

          current? = State.current_result?(state, job.request)

          waiting =
            if current?,
              do:
                Map.take(state.context.tasks[job.request.task_id], [:context_wait, :clarification]),
              else: %{}

          {id,
           Map.merge(
             Map.merge(details, waiting),
             Map.put(identity, :current?, current?)
           )}
        end),
      health: Health.snapshot(state.health),
      playback: state.playback,
      output_recovery: state.output_recovery
    }
  end

  def started(state, event) do
    case state.jobs[event.request_id] do
      %{request: %{task_revision: revision}} = job when revision == event.payload.task_revision ->
        %{
          state
          | jobs:
              Map.put(
                state.jobs,
                event.request_id,
                Map.put_new(job, :started_at_us, event.observed_at_us)
              )
        }

      _other ->
        state
    end
  end

  def delivery(state, request, stage, command_id \\ nil) do
    job = state.jobs[request.id]

    job =
      Map.merge(job, %{
        delivery: stage,
        result_command_id: command_id,
        delivery_updated_at_us: System.monotonic_time(:microsecond)
      })

    payload =
      Map.take(request, [:task_id, :task_revision, :delegation_id]) |> Map.put(:stage, stage)

    State.emit(state, :result_delivery, payload, request_id: request.id, command_id: command_id)
    %{state | jobs: Map.put(state.jobs, request.id, job)}
  end

  def acknowledge(state, %{command_id: nil}), do: state

  def acknowledge(state, event) do
    state = Uncertainty.acknowledge(state, event.command_id, acknowledgment(event))

    case Enum.find(state.jobs, fn {_id, job} ->
           Map.get(job, :result_command_id) == event.command_id
         end) do
      {_id, %{delivery: stage, request: request}}
      when stage in [:awaiting_provider, :unknown, :unconfirmed] ->
        delivery(state, request, acknowledgment(event), event.command_id)

      _other ->
        state
    end
  end

  def playback(state, event) do
    observation =
      Map.take(event.payload, [
        :stage,
        :evidence,
        :stream_id,
        :sequence,
        :epoch,
        :first_sample,
        :end_sample
      ])

    observation = Map.put(observation, :observed_at_us, event.observed_at_us)

    if event.payload.stage in [
         :queued,
         :handed_off,
         :cleared,
         :estimated_playback,
         :device_reported_playback,
         :unknown
       ],
       do: %{state | playback: Map.put(state.playback, event.payload.stage, observation)},
       else: state
  end

  defp acknowledgment(%{payload: %{outcome: :unknown}}), do: :unknown
  defp acknowledgment(%{type: :context_submitted}), do: :unconfirmed
  defp acknowledgment(%{type: :context_acknowledged}), do: :accepted
  defp acknowledgment(_event), do: :rejected

  defp interpretation(%{policy_task: task}) when not is_nil(task), do: :running

  defp interpretation(%{context_resolved?: true} = state) do
    if Enum.any?(state.context.pending_delegations, fn {_id, entry} ->
         entry.status == :pending
       end),
       do: :unresolved,
       else: :settled
  end

  defp interpretation(_state), do: :unresolved
end
