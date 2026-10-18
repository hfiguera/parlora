defmodule Parlora.Backends.Jido do
  @moduledoc """
  Runs a fresh Jido AgentServer for each request, observed outside session/audio callbacks.

  Install optional `jido == 2.4.0` in applications selecting this backend.
  Requires `:agent` and `:result` (terminal Jido state to a map containing `:status`,
  `:facts`, and optional `:summary`). `:signal` maps a BackendRequest to a Jido.Signal;
  its default is `parlora.request`. Optional `:cancel_signal` enables advisory cancellation.
  Cancellation mapping runs in an isolated worker, bounded by
  `limits.cancellation_timeout_ms`, with at most one pending mapping per request
  and `limits.max_jobs` workers. `cancel/4` admits this mapping; correlated
  `:cancellation_requested` or `:cancellation_rejected` events report its outcome.
  Reusing the command ID never reruns the mapping. Mapping failure leaves the
  original work running and does not confirm cancellation.
  A result mapper must explicitly return `status: :cancelled` to confirm cancellation.
  `:agent_options` and `:await_options` stay inside this adapter.
  """
  use GenServer
  @behaviour Parlora.Backend
  alias Parlora.{Adapter, BackendResult, CommandLog, Error, Event, ID}
  alias Parlora.Backend.Capabilities
  alias Parlora.Backends.Jido.{Cancellation, Job}

  @impl true
  def start_link(init, options) do
    cond do
      not Code.ensure_loaded?(Jido.AgentServer) ->
        Error.tuple(:unsupported, "Install optional jido == 2.4.0 to use this backend")

      not is_atom(Keyword.get(options, :agent)) or Keyword.get(options, :agent) == nil or
          not is_function(Keyword.get(options, :result), 1) ->
        Error.tuple(
          :invalid_argument,
          "Jido requires an agent module and result mapping function"
        )

      Keyword.has_key?(options, :cancel_signal) and
          not is_function(options[:cancel_signal], 2) ->
        Error.tuple(:invalid_argument, "Jido cancel_signal must be a two-argument function")

      true ->
        GenServer.start_link(__MODULE__, {init, options})
    end
  end

  @impl true
  def capabilities(pid), do: Adapter.call(pid, :capabilities)
  @impl true
  def submit(pid, request), do: Adapter.call(pid, {:submit, request})
  @impl true
  def update(_pid, _id, _request_id, _replacement),
    do: Error.tuple(:unsupported, "Supersede work to change a Jido request")

  @impl true
  def cancel(pid, id, request_id, reason),
    do: Adapter.call(pid, {:cancel, id, request_id, reason})

  @impl true
  def close(pid, id, reason), do: Adapter.call(pid, {:close, id, reason})

  @impl true
  def init({init, options}) do
    {:ok, workers} = Task.Supervisor.start_link()
    cancellation = if Keyword.has_key?(options, :cancel_signal), do: :advisory, else: :unsupported
    caps = %Capabilities{cancellation: cancellation}
    Event.emit(init, :backend, :ready, %{capabilities: caps})

    {:ok,
     %{
       init: init,
       options: options,
       workers: workers,
       caps: caps,
       jobs: %{},
       uncertain: MapSet.new(),
       refs: %{},
       cancellations: %{},
       cancellation_refs: %{},
       closing: nil,
       commands: %CommandLog{limit: init.limits.max_records}
     }}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl true
  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, state.caps}, state}

  def handle_call({:close, id, policy}, _from, state) do
    state = if state.closing, do: state, else: begin_close(state, id, policy)
    {:reply, :ok, state}
  end

  def handle_call(_command, _from, %{closing: closing} = state) when closing != nil,
    do: {:reply, Error.tuple(:closed, "Backend is closing"), state}

  def handle_call({:submit, request}, _from, state) do
    case CommandLog.admit(state.commands, request.id, request) do
      {:duplicate, _log} -> {:reply, :ok, state}
      {:new, log} -> submit_job(state, log, request)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel, id, request_id, reason}, _from, state) do
    case CommandLog.admit(state.commands, id, {:cancel, request_id, reason}) do
      {:duplicate, _log} ->
        {:reply, :ok, state}

      {:new, log} ->
        case cancel_job(state, id, request_id, reason) do
          {:ok, next} -> {:reply, :ok, %{next | commands: log}}
          error -> {:reply, error, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:jido_started, id, pid}, state) do
    job = %{state.jobs[id] | agent: pid}

    Event.emit(
      state.init,
      :backend,
      :request_started,
      %{task_revision: job.request.task_revision},
      request_id: id
    )

    {:noreply, %{state | jobs: Map.put(state.jobs, id, job)}}
  end

  def handle_info({ref, result}, %{cancellation_refs: refs} = state)
      when is_map_key(refs, ref),
      do: {:noreply, finish_cancellation(state, ref, result)}

  def handle_info({:cancellation_timeout, id, ref}, state) do
    case state.cancellations[id] do
      %{task: %{ref: ^ref}} ->
        {:noreply,
         reject_cancellation(
           state,
           id,
           Error.new(:timeout, "Jido cancellation mapping deadline expired")
         )}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({ref, %BackendResult{} = result}, state) do
    Process.demonitor(ref, [:flush])

    type =
      case result.status do
        :completed -> :request_completed
        :failed -> :request_failed
        :cancelled -> :request_cancelled
      end

    Event.emit(state.init, :backend, type, result, request_id: result.request_id)
    {:noreply, remove_job(state, ref)}
  end

  def handle_info({ref, {:uncertain, :invalid_result}}, state) do
    case state.refs[ref] do
      nil ->
        {:noreply, state}

      id ->
        Process.demonitor(ref, [:flush])
        request = state.jobs[id].request

        Event.emit(
          state.init,
          :backend,
          :request_uncertain,
          %{
            error:
              Error.new(
                :adapter_failed,
                "Jido result mapping failed; external effects require reconciliation"
              ),
            reason: :invalid_result,
            outcome: :unknown,
            task_id: request.task_id,
            task_revision: request.task_revision,
            provider_generation: request.provider_generation
          },
          request_id: id
        )

        {:noreply, remove_job(%{state | uncertain: MapSet.put(state.uncertain, id)}, ref)}
    end
  end

  def handle_info({ref, _late_result}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cancellation_refs: refs} = state)
      when is_map_key(refs, ref) do
    {:noreply,
     reject_cancellation(
       state,
       refs[ref],
       Error.new(:adapter_failed, "Jido cancellation mapper exited")
     )}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.refs[ref] do
      nil ->
        {:noreply, state}

      id ->
        Event.emit(
          state.init,
          :backend,
          :request_uncertain,
          %{
            error:
              Error.new(
                :adapter_failed,
                "Jido observer exited; external effects require reconciliation"
              )
          },
          request_id: id
        )

        {:noreply, %{state | refs: Map.delete(state.refs, ref)}}
    end
  end

  def handle_info({:deadline, id}, state) do
    if Map.has_key?(state.jobs, id) do
      Event.emit(
        state.init,
        :backend,
        :request_uncertain,
        %{error: Error.new(:timeout, "Job deadline elapsed; work may still be running")},
        request_id: id
      )
    end

    {:noreply, state}
  end

  def handle_info(:close_deadline, state) do
    state = stop_cancellations(state, fn _pending -> true end)

    Enum.each(state.jobs, fn {id, job} ->
      Event.emit(state.init, :backend, :request_uncertain, %{reason: :shutdown_deadline},
        request_id: id
      )

      Task.Supervisor.terminate_child(state.workers, job.task.pid)
    end)

    uncertain = MapSet.union(state.uncertain, MapSet.new(Map.keys(state.jobs)))

    Event.emit(state.init, :backend, :closed, %{uncertain_requests: MapSet.to_list(uncertain)},
      command_id: state.closing
    )

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.cancellations, fn {_id, pending} -> Process.exit(pending.task.pid, :kill) end)
    if Process.alive?(state.workers), do: Supervisor.stop(state.workers, :normal)
  end

  defp submit_job(state, log, request) when map_size(state.jobs) < state.init.limits.max_jobs do
    owner = self()
    options = state.options
    task = Task.Supervisor.async_nolink(state.workers, fn -> Job.run(request, options, owner) end)

    remaining =
      if request.deadline_at_us,
        do: max(1, div(request.deadline_at_us - System.monotonic_time(:microsecond), 1_000)),
        else: state.init.limits.job_timeout_ms

    Process.send_after(self(), {:deadline, request.id}, remaining)
    job = %{request: request, task: task, agent: nil}

    {:reply, :ok,
     %{
       state
       | commands: log,
         jobs: Map.put(state.jobs, request.id, job),
         refs: Map.put(state.refs, task.ref, request.id)
     }}
  end

  defp submit_job(state, _log, _request),
    do: {:reply, Error.tuple(:backpressure, "Jido job capacity exhausted"), state}

  defp cancel_job(%{caps: %{cancellation: :unsupported}}, _id, _request_id, _reason),
    do: Error.tuple(:unsupported, "No Jido cancellation mapping configured")

  defp cancel_job(state, id, request_id, reason) do
    case state.jobs[request_id] do
      %{agent: pid, request: request} when is_pid(pid) ->
        launch_cancellation(state, id, request, reason)

      _not_started ->
        Error.tuple(:not_ready, "Jido request has no running agent")
    end
  end

  defp begin_close(state, id, policy) do
    state = if policy == :cancel, do: cancel_all_jobs(state), else: state

    Process.send_after(
      self(),
      :close_deadline,
      max(1, state.init.limits.shutdown_timeout_ms - 50)
    )

    state = %{state | closing: id}
    maybe_closed(state)
  end

  defp cancel_all_jobs(state) do
    Enum.reduce(state.jobs, state, fn {request_id, _job}, acc ->
      case cancel_job(acc, ID.new(), request_id, :session_closed) do
        {:ok, next} -> next
        _not_admitted -> acc
      end
    end)
  end

  defp remove_job(state, ref) do
    {id, refs} = Map.pop(state.refs, ref)

    state
    |> Map.merge(%{refs: refs, jobs: Map.delete(state.jobs, id)})
    |> stop_cancellations(&(&1.request_id == id))
    |> maybe_closed()
  end

  defp launch_cancellation(state, id, request, reason) do
    if map_size(state.cancellations) < state.init.limits.max_jobs and
         not Enum.any?(state.cancellations, fn {_id, pending} ->
           pending.request_id == request.id
         end) do
      mapper = Keyword.fetch!(state.options, :cancel_signal)

      task =
        Task.Supervisor.async_nolink(
          state.workers,
          fn -> Cancellation.map(mapper, request, reason) end,
          shutdown: :brutal_kill
        )

      timer =
        Process.send_after(
          self(),
          {:cancellation_timeout, id, task.ref},
          state.init.limits.cancellation_timeout_ms
        )

      pending = %{request_id: request.id, task: task, timer: timer}

      {:ok,
       %{
         state
         | cancellations: Map.put(state.cancellations, id, pending),
           cancellation_refs: Map.put(state.cancellation_refs, task.ref, id)
       }}
    else
      Error.tuple(:backpressure, "Jido cancellation mapping capacity exhausted")
    end
  end

  defp finish_cancellation(state, ref, result) do
    id = state.cancellation_refs[ref]
    pending = state.cancellations[id]

    outcome =
      case {state.jobs[pending.request_id], result} do
        {%{agent: agent}, {:ok, signal}} when is_pid(agent) -> Cancellation.submit(agent, signal)
        {_job, {:error, error}} -> {:error, error}
        _finished -> Error.tuple(:not_ready, "Jido request has no running agent")
      end

    case outcome do
      :ok ->
        Event.emit(state.init, :backend, :cancellation_requested, %{outcome: :requested},
          command_id: id,
          request_id: pending.request_id
        )

        release_cancellation(state, id)

      {:error, error} ->
        reject_cancellation(state, id, error)
    end
  end

  defp reject_cancellation(state, id, error) do
    pending = state.cancellations[id]

    Event.emit(state.init, :backend, :cancellation_rejected, %{error: error},
      command_id: id,
      request_id: pending.request_id
    )

    release_cancellation(state, id)
  end

  defp release_cancellation(state, id) do
    {pending, cancellations} = Map.pop(state.cancellations, id)
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.task.ref, [:flush])
    Process.exit(pending.task.pid, :kill)

    %{
      state
      | cancellations: cancellations,
        cancellation_refs: Map.delete(state.cancellation_refs, pending.task.ref)
    }
  end

  defp stop_cancellations(state, predicate) do
    Enum.reduce(state.cancellations, state, fn {id, pending}, acc ->
      if predicate.(pending),
        do:
          reject_cancellation(acc, id, Error.new(:closed, "Jido request is no longer observed")),
        else: acc
    end)
  end

  defp maybe_closed(%{closing: id, jobs: jobs} = state) when id != nil and map_size(jobs) == 0 do
    Event.emit(
      state.init,
      :backend,
      :closed,
      %{uncertain_requests: MapSet.to_list(state.uncertain)},
      command_id: id
    )

    state
  end

  defp maybe_closed(state), do: state
end
