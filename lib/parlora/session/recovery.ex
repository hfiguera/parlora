defmodule Parlora.Session.Recovery do
  @moduledoc false
  alias Parlora.{AudioPipeline, ID, Telemetry}
  alias Parlora.Session.{Commands, Shutdown}

  def request(state, %{token: token} = payload) do
    {module, pid} = state.adapters.provider

    if (is_nil(state.output_recovery) or match?(%{stage: :awaiting_user}, state.output_recovery)) and
         function_exported?(module, :recover_output, 3) do
      pipeline = state.output_pipeline
      context = recovery_context(state)

      callback = fn -> recover_after_clear(pipeline, module, pid, token, context) end

      state = %{
        state
        | output_recovery:
            Map.merge(payload, %{
              stage: :reconnecting,
              started_at_us: System.monotonic_time(:microsecond),
              telemetry:
                Telemetry.start(:recovery, %{
                  session_id: state.id,
                  parent_operation_id: state.startup.telemetry_session.metadata.operation_id
                })
            })
      }

      queue_recovery(state, callback)
    else
      Shutdown.begin(state, :cancel)
    end
  end

  def recovered(
        %{output_recovery: %{token: token, stage: :reconnecting, telemetry: telemetry}} = state,
        token
      ) do
    Telemetry.stop(telemetry, :reconnected)
    # The adapter's connection incarnation changed. Tasks and their revision /
    # execution identity did not; no backend submit or retry occurs here.
    %{
      state
      | output_recovery:
          state.output_recovery |> Map.put(:stage, :awaiting_user) |> Map.delete(:telemetry)
    }
  end

  def recovered(state, _token), do: state

  def interrupted(state, token) do
    {module, pid} = state.adapters.provider

    if function_exported?(module, :resume_output, 2) do
      pipeline = state.output_pipeline

      telemetry =
        Telemetry.start(:interruption, %{
          session_id: state.id,
          parent_operation_id: state.startup.telemetry_session.metadata.operation_id
        })

      callback = fn -> resume_after_clear(pipeline, module, pid, token) end

      queue_recovery(state, callback, telemetry)
    else
      Shutdown.begin(state, :cancel)
    end
  end

  defp recover_after_clear(pipeline, module, pid, token, context) do
    with :ok <- AudioPipeline.control(pipeline, ID.new(), {:provider_interrupted, token}),
         do: module.recover_output(pid, token, context)
  end

  defp resume_after_clear(pipeline, module, pid, token) do
    with :ok <- AudioPipeline.control(pipeline, ID.new(), {:provider_interrupted, token}),
         do: module.resume_output(pid, token)
  end

  defp queue_recovery(state, callback, telemetry \\ nil) do
    complete = fn current, reply ->
      Telemetry.stop(telemetry, if(reply == :ok, do: :completed, else: :unknown))
      if(reply == :ok, do: current, else: Shutdown.begin(current, :cancel))
    end

    case Commands.enqueue(state, :provider, callback, complete) do
      {:ok, next} ->
        next

      _error ->
        Telemetry.stop(telemetry, :rejected)
        Shutdown.begin(state, :cancel)
    end
  end

  defp recovery_context(state) do
    tasks =
      Map.new(state.context.tasks, fn {id, task} ->
        result =
          case task.request_ids do
            [request_id | _older] -> Map.get(state.jobs[request_id], :result)
            [] -> nil
          end

        task =
          if result && result.task_revision == task.revision,
            do: Map.put(task, :recovery_result, Map.take(result, [:status, :summary])),
            else: task

        {id, task}
      end)

    %{state.context | tasks: tasks}
  end
end
