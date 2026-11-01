defmodule Parlora.Session.Shutdown do
  @moduledoc false
  alias Parlora.{AdapterOwner, ID, Telemetry}
  alias Parlora.Session.{Commands, Health, Interpretation, State}

  def finish(state, message) do
    Interpretation.stop(state)
    Enum.each(state.startup.owners, fn {_role, owner} -> AdapterOwner.cancel(owner.watcher) end)

    event =
      State.emit(state, :closed, %{
        finalized?: state.finalization,
        usage: state.usage,
        health: Health.snapshot(state.health),
        jobs: job_outcomes(state)
      })

    State.broadcast(state, event)

    state = %{
      state
      | jobs: Map.new(state.jobs, fn {id, job} -> {id, Telemetry.close_job(job)} end)
    }

    timed_out? =
      message == :shutdown_timeout or
        System.monotonic_time(:microsecond) >= state.startup.telemetry_shutdown.deadline_us

    Telemetry.stop(
      state.startup.telemetry_shutdown,
      if(timed_out?, do: :timeout, else: :completed)
    )

    Telemetry.stop(state.startup.telemetry_session, :closed)

    {:stop, :normal,
     %{state | startup: %{state.startup | telemetry_session: nil, telemetry_shutdown: nil}}}
  end

  def terminate(reason, state) do
    outcome =
      if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
        do: :closed,
        else: :error

    Telemetry.stop(
      state.startup.telemetry_startup,
      if(outcome == :closed, do: :cancelled, else: :failed)
    )

    Telemetry.stop(state.startup.telemetry_shutdown, outcome)
    Telemetry.stop(get_in(state.output_recovery || %{}, [:telemetry]), :error)

    Enum.each(state.jobs, fn {_id, job} -> Telemetry.close_job(job) end)

    abort_startup(state)
    Interpretation.stop(state)
    Telemetry.stop(state.startup.telemetry_session, outcome)
  end

  def begin(%{status: :closing} = state, _policy), do: state

  def begin(state, policy) do
    Telemetry.stop(state.startup.telemetry_startup, :cancelled)

    telemetry =
      Telemetry.start(:shutdown, %{
        session_id: state.id,
        parent_operation_id: state.startup.telemetry_session.metadata.operation_id
      })

    Telemetry.stop(get_in(state.output_recovery || %{}, [:telemetry]), :closed)

    state =
      if state.output_recovery,
        do: %{state | output_recovery: Map.delete(state.output_recovery, :telemetry)},
        else: state

    deadline = System.monotonic_time(:microsecond) + state.limits.shutdown_timeout_ms * 1_000
    Process.send_after(self(), :shutdown_timeout, state.limits.shutdown_timeout_ms)
    starting? = state.status == :starting
    abort_startup(state)

    state = %{
      state
      | status: :closing,
        startup: %{
          state.startup
          | pending: nil,
            telemetry_startup: nil,
            telemetry_shutdown: Map.put(telemetry, :deadline_us, deadline)
        }
    }

    state = Commands.close(state)
    state = State.update_health(state, Health.close(state.health))

    cleanup =
      [
        Interpretation.stop(state, self())
        | Enum.map([state.input_pipeline, state.output_pipeline], &AdapterOwner.stop(&1, self()))
      ]
      |> Enum.filter(&is_pid/1)
      |> MapSet.new()

    state = %{state | policy_task: nil, startup: %{state.startup | cleanup: cleanup}}

    # Startup cleanup cannot call into adapters that may still be in init or
    # readiness work. Their owners stop them independently of this coordinator.
    unless starting?, do: close_adapters(state, policy, deadline)

    jobs =
      Map.new(state.jobs, fn {id, job} ->
        job = Telemetry.close_job(job)

        {id, if(job.status == :queued, do: %{job | status: :cancelled}, else: job)}
      end)

    settle(%{
      state
      | status: :closing,
        jobs: jobs,
        health: state.health
    })
  end

  defp close_adapters(state, policy, deadline) do
    Enum.each(state.startup.owners, fn {role, owner} ->
      AdapterOwner.close(
        owner.watcher,
        ID.new(),
        if(role == :backend, do: policy, else: :session_closed),
        deadline
      )
    end)
  end

  def settle(state) do
    if MapSet.size(state.startup.cleanup) == 0 and
         Enum.all?(Map.keys(state.startup.owners), &MapSet.member?(state.closing_adapters, &1)),
       do: send(self(), :shutdown_settled)

    state
  end

  defp abort_startup(%{status: :starting} = state) do
    Enum.each(state.startup.owners, fn {_role, owner} -> AdapterOwner.cancel(owner.watcher) end)
  end

  defp abort_startup(_state), do: :ok

  defp job_outcomes(state) do
    Map.new(state.jobs, fn {id, job} ->
      outcome = if job.status == :submitted, do: :uncertain, else: job.status
      {id, outcome}
    end)
  end
end
