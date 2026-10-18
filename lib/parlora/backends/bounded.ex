defmodule Parlora.Backends.Bounded do
  @moduledoc false
  use GenServer
  alias Parlora.{Adapter, BackendRequest, CommandLog, Error, Event}
  alias Parlora.Backend.Capabilities

  def start_link(init, options, runner) do
    with :ok <- runner.configuration(options),
         :ok <- validate_limits(init.limits) do
      GenServer.start_link(__MODULE__, {init, options, runner})
    end
  end

  defp validate_limits(limits) do
    if Enum.all?(
         [:max_jobs, :max_records, :job_timeout_ms, :shutdown_timeout_ms],
         &finite_limit?(Map.get(limits, &1))
       ) do
      :ok
    else
      Error.tuple(:invalid_argument, "Backend limits must be finite positive integers")
    end
  end

  defp finite_limit?(value), do: is_integer(value) and value > 0 and value <= 4_294_967_295

  def capabilities(pid), do: Adapter.call(pid, :capabilities)
  def submit(pid, request), do: Adapter.call(pid, {:submit, request})

  def cancel(pid, id, request_id, reason),
    do: Adapter.call(pid, {:cancel, id, request_id, reason})

  def close(pid, id, policy), do: Adapter.call(pid, {:close, id, policy})

  @impl true
  def init({init, options, runner}) do
    {:ok, workers} = Task.Supervisor.start_link()
    caps = %Capabilities{cancellation: :advisory}
    Event.emit(init, :backend, :ready, %{capabilities: caps})

    {:ok,
     %{
       init: init,
       options: options,
       runner: runner,
       workers: workers,
       caps: caps,
       jobs: %{},
       refs: %{},
       commands: %CommandLog{limit: init.limits.max_records},
       closing: nil,
       closed?: false,
       close_timer: nil,
       uncertain: MapSet.new()
     }}
  end

  @impl true
  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, state.caps}, state}

  def handle_call({:close, id, policy} = command, _from, state) do
    CommandLog.run(state, id, command, fn current, command_id, _command ->
      close_execution(current, command_id, policy)
    end)
  end

  def handle_call({:submit, %BackendRequest{} = request}, _from, state) do
    CommandLog.run(state, request.id, request, fn current, _id, admitted ->
      launch(current, admitted)
    end)
  end

  def handle_call({:cancel, id, request_id, reason} = command, _from, state) do
    CommandLog.run(state, id, command, fn current, command_id, _command ->
      request_stop(current, command_id, request_id, reason)
    end)
  end

  @impl true
  def handle_info({:execution_started, id}, state) do
    case state.jobs[id] do
      %{request: request, stopping: nil} ->
        Event.emit(
          state.init,
          :backend,
          :request_started,
          %{
            task_id: request.task_id,
            task_revision: request.task_revision,
            provider_generation: request.provider_generation
          },
          request_id: id
        )

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({ref, outcome}, state) when is_reference(ref) do
    case state.refs[ref] do
      nil ->
        {:noreply, state}

      id ->
        Process.demonitor(ref, [:flush])
        job = state.jobs[id]
        state = publish(state, job, outcome)
        {:noreply, release(state, id)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.refs[ref] do
      nil ->
        {:noreply, state}

      id ->
        reason = state.jobs[id].stopping || :observer_exited
        state = publish_uncertain(state, id, reason)
        {:noreply, release(state, id)}
    end
  end

  def handle_info({:execution_deadline, id}, state),
    do: {:noreply, stop_execution(state, id, :execution_deadline)}

  def handle_info(:execution_close_deadline, state) do
    state = Enum.reduce(Map.keys(state.jobs), state, &stop_execution(&2, &1, :shutdown_deadline))
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.jobs, fn {_id, job} -> Process.exit(job.task.pid, :kill) end)
    if Process.alive?(state.workers), do: Supervisor.stop(state.workers, :normal, 1_000)
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp launch(%{closing: id} = state, _request) when id != nil,
    do: {:reply, Error.tuple(:closed, "Backend is closing"), state}

  defp launch(state, request) do
    remaining = remaining_ms(request, state.init.limits.job_timeout_ms)

    cond do
      map_size(state.jobs) >= state.init.limits.max_jobs ->
        {:reply, Error.tuple(:backpressure, "#{state.runner.name()} job capacity exhausted"),
         state}

      remaining <= 0 ->
        {:reply, Error.tuple(:timeout, "Request deadline already elapsed"), state}

      true ->
        owner = self()
        options = state.options
        runner = state.runner

        task =
          Task.Supervisor.async_nolink(
            state.workers,
            fn -> runner.run(request, options, owner) end,
            shutdown: :brutal_kill
          )

        timer =
          Process.send_after(
            self(),
            {:execution_deadline, request.id},
            remaining
          )

        job = %{request: request, task: task, timer: timer, stopping: nil}

        {:reply, :ok,
         %{
           state
           | jobs: Map.put(state.jobs, request.id, job),
             refs: Map.put(state.refs, task.ref, request.id)
         }}
    end
  end

  defp remaining_ms(%{deadline_at_us: nil}, limit), do: limit

  defp remaining_ms(request, limit),
    do: min(limit, div(request.deadline_at_us - System.monotonic_time(:microsecond), 1_000))

  defp request_stop(%{closing: id} = state, _command_id, _request_id, _reason) when id != nil,
    do: {:reply, Error.tuple(:closed, "Backend is closing"), state}

  defp request_stop(state, id, request_id, _reason) do
    if Map.has_key?(state.jobs, request_id) do
      Event.emit(state.init, :backend, :cancellation_requested, %{outcome: :requested},
        command_id: id,
        request_id: request_id
      )

      {:reply, :ok, stop_execution(state, request_id, :cancellation_requested)}
    else
      {:reply, Error.tuple(:not_ready, "#{state.runner.name()} request has no active execution"),
       state}
    end
  end

  defp stop_execution(state, id, reason) do
    case state.jobs[id] do
      %{stopping: nil} = job ->
        Process.exit(job.task.pid, :kill)
        %{state | jobs: Map.put(state.jobs, id, %{job | stopping: reason})}

      _ ->
        state
    end
  end

  defp close_execution(%{closing: id} = state, _command_id, _policy) when id != nil,
    do: {:reply, Error.tuple(:closed, "Backend already has a close command"), state}

  defp close_execution(state, id, policy) when policy in [:finish, :cancel] do
    timer =
      Process.send_after(
        self(),
        :execution_close_deadline,
        max(1, state.init.limits.shutdown_timeout_ms - 50)
      )

    state = %{state | closing: id, close_timer: timer}

    state =
      if policy == :cancel,
        do: Enum.reduce(Map.keys(state.jobs), state, &stop_execution(&2, &1, :session_closed)),
        else: state

    {:reply, :ok, finish_close(state)}
  end

  defp close_execution(state, _id, _policy),
    do: {:reply, Error.tuple(:invalid_argument, "Close policy must be finish or cancel"), state}

  defp publish(state, %{stopping: reason, request: request}, _outcome) when reason != nil,
    do: publish_uncertain(state, request.id, reason)

  defp publish(state, job, {:ok, result}) do
    type = if result.status == :completed, do: :request_completed, else: :request_failed
    Event.emit(state.init, :backend, type, result, request_id: job.request.id)
    state
  end

  defp publish(state, job, {:uncertain, reason}),
    do: publish_uncertain(state, job.request.id, reason)

  defp publish_uncertain(state, id, reason) do
    Event.emit(
      state.init,
      :backend,
      :request_uncertain,
      %{
        error:
          Error.new(
            :adapter_failed,
            "#{state.runner.name()} execution stopped; external effects require reconciliation"
          ),
        reason: reason,
        outcome: :unknown,
        task_id: state.jobs[id].request.task_id,
        task_revision: state.jobs[id].request.task_revision,
        provider_generation: state.jobs[id].request.provider_generation
      },
      request_id: id
    )

    %{state | uncertain: MapSet.put(state.uncertain, id)}
  end

  defp release(state, id) do
    {job, jobs} = Map.pop(state.jobs, id)
    Process.cancel_timer(job.timer)
    finish_close(%{state | jobs: jobs, refs: Map.delete(state.refs, job.task.ref)})
  end

  defp finish_close(%{closing: id, closed?: false, jobs: jobs} = state)
       when id != nil and map_size(jobs) == 0 do
    Process.cancel_timer(state.close_timer)

    Event.emit(
      state.init,
      :backend,
      :closed,
      %{uncertain_requests: MapSet.to_list(state.uncertain)},
      command_id: id
    )

    %{state | closed?: true}
  end

  defp finish_close(state), do: state
end
