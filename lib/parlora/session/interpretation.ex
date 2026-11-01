defmodule Parlora.Session.Interpretation do
  @moduledoc false
  alias Parlora.{AdapterOwner, Error, ProcessTree, SessionSupervisor, Telemetry}
  alias Parlora.Session.{Decisions, State}

  @type transition :: {:ok, State.t()} | {:close, State.t()}

  @spec result(State.t(), term()) :: transition()
  def result(%{policy_task: work} = state, result) do
    ref = work.ref
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(work.timer)
    outcome = if match?({:ok, _}, result), do: :ok, else: :error

    outcome =
      if match?({:ok, _}, result) and state.context.revision != work.revision,
        do: :superseded,
        else: outcome

    Telemetry.stop(work.telemetry, outcome)
    state = %{state | policy_task: nil}

    if state.status == :ready and
         (state.context.revision == work.revision or not match?({:ok, _}, result)) do
      apply_policy(state, result)
    else
      {:ok, start(state, state.policy_trigger)}
    end
  end

  @spec timeout(State.t()) :: transition()
  def timeout(%{policy_task: work} = state) do
    ref = work.ref
    Telemetry.stop(work.telemetry, :timeout)
    Task.Supervisor.terminate_child(SessionSupervisor.via(state.id, :tasks), work.pid)
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(work.timer)

    policy_failed(
      %{state | policy_task: nil},
      Error.new(:timeout, "Context policy deadline expired")
    )
  end

  @spec down(State.t()) :: transition()
  def down(%{policy_task: work} = state) do
    Process.cancel_timer(work.timer)
    Telemetry.stop(work.telemetry, :error)

    policy_failed(
      %{state | policy_task: nil},
      Error.new(:adapter_failed, "Context policy exited")
    )
  end

  def start(%{status: :ready, policy_task: nil} = state, trigger) do
    {module, options} = state.policy
    snapshot = state.context
    tasks = GenServer.whereis(SessionSupervisor.via(state.id, :tasks))

    telemetry =
      Telemetry.start(:policy, %{
        session_id: state.id,
        parent_operation_id: state.startup.telemetry_session.metadata.operation_id
      })

    task =
      Task.Supervisor.async_nolink(
        tasks,
        fn ->
          ProcessTree.track(tasks)
          module.interpret(snapshot, trigger, options)
        end,
        shutdown: :brutal_kill
      )

    timer =
      Process.send_after(self(), {:policy_timeout, task.ref}, state.limits.policy_timeout_ms)

    %{
      state
      | policy_task: %{
          ref: task.ref,
          pid: task.pid,
          revision: snapshot.revision,
          timer: timer,
          telemetry: telemetry
        },
        policy_trigger: trigger,
        context_resolved?: false
    }
  end

  def start(state, trigger), do: %{state | policy_trigger: trigger, context_resolved?: false}

  defp apply_policy(state, {:ok, decisions}) do
    case Decisions.apply_batch(state, decisions) do
      {:ok, next} ->
        unresolved =
          Enum.any?(
            decisions,
            &(&1.kind in [:wait_for_context, :request_clarification] and is_binary(&1.task_id))
          )

        {:ok, %{next | context_resolved?: not unresolved, policy_failures: 0}}

      {:error, error} ->
        State.emit(state, :policy_rejected, %{error: error})

        if error.code == :backpressure and
             Enum.any?(decisions, &(&1.kind in [:supersede_task, :update_task])),
           do: {:close, state},
           else: {:ok, state}
    end
  end

  defp apply_policy(state, _error),
    do: policy_failed(state, Error.new(:adapter_failed, "Context policy failed"))

  defp policy_failed(%{status: status} = state, _error) when status != :ready, do: {:ok, state}

  defp policy_failed(state, error) do
    failures = state.policy_failures + 1
    retry? = failures == 1

    State.emit(state, :policy_failed, %{
      error: error,
      attempt: failures,
      retry?: retry?
    })

    state = %{state | policy_failures: failures}

    if retry? do
      # Reinterpret the latest context only. Never submit/replay backend work or
      # release held results until a valid decision batch settles that context.
      {:ok, start(state, state.policy_trigger)}
    else
      State.emit(state, :failed, %{
        cause: :policy_failed,
        error: Error.new(:adapter_failed, "Context interpretation failed after one retry")
      })

      {:close, state}
    end
  end

  def stop(state, notify \\ nil)

  def stop(%{policy_task: nil}, _notify), do: nil

  def stop(state, notify) do
    Telemetry.stop(state.policy_task.telemetry, :cancelled)
    Process.cancel_timer(state.policy_task.timer)
    Process.demonitor(state.policy_task.ref, [:flush])
    AdapterOwner.stop(state.policy_task.pid, notify)
  end
end
