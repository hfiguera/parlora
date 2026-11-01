defmodule Parlora.Session do
  @moduledoc false
  use GenServer

  alias Parlora.{
    Adapter,
    AudioPipeline,
    BackendResult,
    ContextTrigger,
    ContextUpdate,
    Error,
    Event
  }

  alias Parlora.Session.{
    Commands,
    ContextWait,
    Decisions,
    Health,
    Interpretation,
    Jobs,
    Progress,
    Recovery,
    Shutdown,
    Startup,
    State,
    Uncertainty
  }

  alias Parlora.SessionSupervisor

  def start_link(options) do
    GenServer.start_link(__MODULE__, options,
      name: SessionSupervisor.via(Keyword.fetch!(options, :id), :session)
    )
  end

  def subscribe(pid, subscriber), do: Adapter.call(pid, {:subscribe, subscriber})
  def snapshot(pid), do: Adapter.call(pid, :snapshot)
  def status(pid), do: Adapter.call(pid, :status)

  def expect_progress(pid, id, timeout_ms, options),
    do: Adapter.call(pid, {:expect_progress, id, timeout_ms, options})

  def resolve_progress(pid, id, outcome),
    do: Adapter.call(pid, {:resolve_progress, id, outcome})

  def update_context(pid, context), do: Adapter.call(pid, {:context, context})
  def append_context(pid, update), do: Adapter.call(pid, {:append_context, update})

  def cancel(pid, id, request_id, reason),
    do: Adapter.call(pid, {:cancel, id, request_id, reason})

  def control(pid, id, control), do: Adapter.call(pid, {:control, id, control})
  def close(pid, policy), do: Adapter.call(pid, {:close, policy})

  @impl true
  def init(options) do
    state = State.new(options)
    subscriber = Keyword.get(options, :event_sink)
    state = if is_pid(subscriber), do: add_subscriber(state, subscriber), else: state
    {:ok, state}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: %{status: status.state.status}, message: :redacted})

  @impl true
  def handle_continue(:start_adapters, state), do: {:noreply, Startup.start(state)}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    if Map.has_key?(state.subscribers, pid) or
         map_size(state.subscribers) < state.limits.max_subscribers,
       do: {:reply, :ok, add_subscriber(state, pid)},
       else: {:reply, Error.tuple(:backpressure, "Subscriber capacity exhausted"), state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state.context, state}
  def handle_call(:status, _from, state), do: {:reply, Progress.snapshot(state), state}

  def handle_call({:expect_progress, id, timeout_ms, options}, _from, %{status: :ready} = state) do
    {reply, health} = Health.expect(state.health, id, timeout_ms, options)
    {:reply, reply, State.update_health(state, health)}
  end

  def handle_call({:resolve_progress, id, outcome}, _from, %{status: :ready} = state) do
    {reply, health} = Health.resolve(state.health, id, outcome)
    {:reply, reply, State.update_health(state, health)}
  end

  def handle_call({:append_context, %ContextUpdate{} = update}, from, %{status: :ready} = state) do
    if update.provider_generation == state.context.provider_generation and
         (update.task_id == nil or State.current_result?(state, update)) do
      {module, pid} = state.adapters.provider

      Commands.public(state, :provider, fn -> module.append_context(pid, update) end, from,
        guard: fn current ->
          update.provider_generation == current.context.provider_generation and
            (update.task_id == nil or State.current_result?(current, update))
        end
      )
    else
      {:reply, Error.tuple(:invalid_argument, "Stale context update"), state}
    end
  end

  def handle_call({:cancel, id, request_id, reason}, from, %{status: :ready} = state),
    do: Jobs.cancel(state, id, request_id, reason, from)

  def handle_call({:context, context}, _from, %{status: :ready} = state) when is_map(context) do
    state = State.revise(state, %{state.context | application_context: context})

    {:reply, :ok,
     Interpretation.start(state, %ContextTrigger{kind: :application_context_updated})}
  end

  def handle_call(
        {:control, id, {:input_muted, _flag} = control},
        from,
        %{status: :ready} = state
      ) do
    {module, pid} = state.adapters.provider
    Commands.public(state, :provider, fn -> module.control(pid, id, control) end, from)
  end

  def handle_call({:control, id, control}, from, %{status: :ready} = state) do
    pipeline = state.output_pipeline

    Commands.public(
      state,
      :provider,
      fn -> AudioPipeline.control(pipeline, id, control) end,
      from
    )
  end

  def handle_call({:close, policy}, _from, state) when policy in [:cancel, :finish] do
    {:reply, :ok, Shutdown.begin(state, policy)}
  end

  def handle_call(_command, _from, state),
    do: {:reply, Error.tuple(:not_ready, "Session is not ready for this command"), state}

  @impl true
  def handle_info(:start_adapters, %{status: :starting, startup: %{deadline_us: nil}} = state),
    do: {:noreply, state, {:continue, :start_adapters}}

  def handle_info(
        {:parlora_adapter_started, owner, pid},
        %{status: :starting, startup: %{pending: %{owner: owner, role: role, module: module}}} =
          state
      ) do
    {:noreply, Startup.adapter_started(state, role, module, pid)}
  end

  def handle_info(
        {:parlora_adapter_failed, owner, reason},
        %{status: :starting, startup: %{pending: %{owner: owner}}} = state
      ),
      do: {:noreply, Startup.failed(state, reason)}

  def handle_info(
        {:parlora_pipeline_ready, pid, token},
        %{status: :starting, startup: %{pipeline_token: token}} = state
      )
      when is_reference(token) do
    {:noreply, Startup.pipeline_ready(state, pid)}
  end

  def handle_info({:context_wait, key, token}, %{status: :ready} = state) do
    {state, trigger} = ContextWait.expire(state, key, token)
    {:noreply, if(trigger, do: Interpretation.start(state, trigger), else: state)}
  end

  def handle_info({:parlora_event, %Event{source: :session} = event}, state) do
    {:noreply, State.broadcast(state, event)}
  end

  def handle_info({:parlora_event, %Event{} = event}, state) do
    if current_adapter?(state, event) do
      state = State.broadcast(state, event)
      state = State.update_health(state, Health.observe(state.health, event))
      {:noreply, apply_event(state, event)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:progress_deadline, token}, %{status: :ready} = state) do
    {action, health} = Health.expire(state.health, token)
    state = State.update_health(state, health)

    if action == :close do
      State.emit(state, :failed, %{
        cause: :progress_timeout,
        health: Health.snapshot(state.health),
        error: Error.new(:timeout, "Expected session progress was not observed")
      })

      {:noreply, Shutdown.begin(state, :cancel)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{policy_task: %{ref: ref}} = state),
    do:
      {:noreply,
       state
       |> Interpretation.result(result)
       |> policy_transition()
       |> Jobs.deliver_pending()}

  def handle_info({:policy_timeout, ref}, %{policy_task: %{ref: ref}} = state),
    do: {:noreply, state |> Interpretation.timeout() |> policy_transition()}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{policy_task: %{ref: ref}} = state),
    do: {:noreply, state |> Interpretation.down() |> policy_transition()}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.monitors[ref] do
      nil ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

      role ->
        State.emit(state, :adapter_down, %{role: role})

        state =
          if Map.has_key?(state.startup.owners, role),
            do: %{state | closing_adapters: MapSet.put(state.closing_adapters, role)},
            else: state

        {:noreply, state |> Shutdown.begin(:cancel) |> Shutdown.settle()}
    end
  end

  def handle_info({:parlora_command_result, reference, reply}, state),
    do:
      {:noreply,
       Commands.result(state, reference, reply)
       |> Jobs.deliver_pending()
       |> Decisions.dispatch_pending()}

  def handle_info({:adapter_command_timeout, reference}, state) do
    {next, stalled?} = Commands.timeout(state, reference)

    if stalled?,
      do:
        State.emit(next, :failed, %{
          error: Error.new(:timeout, "Adapter command stalled; admission is uncertain")
        })

    {:noreply, if(stalled?, do: Shutdown.begin(next, :cancel), else: next)}
  end

  def handle_info(:startup_timeout, %{status: :starting} = state) do
    {:noreply, Startup.failed(state, :timeout)}
  end

  def handle_info({:parlora_process_stopped, worker}, %{status: :closing} = state) do
    state = %{
      state
      | startup: %{state.startup | cleanup: MapSet.delete(state.startup.cleanup, worker)}
    }

    {:noreply, Shutdown.settle(state)}
  end

  def handle_info({:cancellation_deadline, id, request_id}, state),
    do: {:noreply, Jobs.cancellation_deadline(state, id, request_id)}

  def handle_info({:job_deadline, id}, state), do: {:noreply, Jobs.deadline(state, id)}

  def handle_info(message, state) when message in [:shutdown_timeout, :shutdown_settled],
    do: Shutdown.finish(state, message)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state), do: Shutdown.terminate(reason, state)

  defp policy_transition({:ok, state}), do: state
  defp policy_transition({:close, state}), do: Shutdown.begin(state, :cancel)

  defp current_adapter?(state, event) do
    case Keyword.get(state.options, event.source) do
      {%Parlora.AdapterInit{adapter_id: id, generation: generation}, _options} ->
        event.adapter_id == id and event.generation == generation

      _other ->
        false
    end
  end

  defp apply_event(state, %Event{type: :ready, source: role, payload: payload}),
    do: Startup.ready(state, role, payload.capabilities)

  defp apply_event(%{status: :ready} = state, %Event{type: :transcript_delta, payload: payload}) do
    if length(state.context.transcripts) < state.limits.max_transcripts do
      state =
        if payload.speaker == :user and String.trim(payload.delta) != "" and
             match?(%{stage: :awaiting_user}, state.output_recovery),
           do: %{state | output_recovery: nil},
           else: state

      entry =
        Map.merge(payload, %{
          provider_generation: state.context.provider_generation,
          arrival_order: state.context.revision
        })

      state =
        State.revise(state, %{state.context | transcripts: [entry | state.context.transcripts]})

      Interpretation.start(state, %ContextTrigger{kind: :transcript_updated})
    else
      State.emit(state, :failed, %{
        error: Error.new(:backpressure, "Transcript capacity exhausted")
      })

      Shutdown.begin(state, :cancel)
    end
  end

  defp apply_event(%{status: :ready} = state, %Event{
         type: :delegation_requested,
         payload: payload
       }) do
    pending = state.context.pending_delegations

    cond do
      Map.has_key?(pending, payload.id) ->
        state

      Enum.count(pending, fn {_id, entry} -> entry.status == :pending end) >=
        state.limits.max_pending_delegations or
          map_size(pending) >= state.limits.max_records ->
        State.emit(state, :admission_rejected, %{
          error: Error.new(:backpressure, "Delegation capacity exhausted")
        })

        Decisions.resolve_delegation(state, payload.id, %{status: :rejected, reason: :capacity})

      true ->
        entry =
          Map.merge(payload, %{
            status: :pending,
            received_at_us: System.monotonic_time(:microsecond),
            provider_generation: state.context.provider_generation
          })

        state =
          State.revise(state, %{
            state.context
            | pending_delegations: Map.put(pending, payload.id, entry)
          })

        State.emit(state, :delegation_pending, %{delegation_id: payload.id})
        Interpretation.start(state, %ContextTrigger{kind: :delegation, delegation_id: payload.id})
    end
  end

  defp apply_event(state, %Event{source: :backend, type: :request_started} = event),
    do: Progress.started(state, event)

  defp apply_event(state, %Event{source: :provider, type: type} = event)
       when type in [:context_acknowledged, :context_rejected, :context_submitted],
       do: Progress.acknowledge(state, event)

  defp apply_event(state, %Event{
         source: :provider,
         type: :provider_activity,
         payload: %{state: activity}
       }),
       do: %{state | provider_activity: activity}

  defp apply_event(state, %Event{
         source: :provider,
         type: :provider_speech,
         payload: %{state: speech}
       }) do
    if state.provider_speech == speech do
      state
    else
      State.revise(%{state | provider_speech: speech}, %{state.context | provider_speech: speech})
    end
  end

  defp apply_event(%{status: :ready} = state, %Event{
         source: :provider,
         type: :output_recovery_requested,
         payload: %{token: _token} = payload
       }),
       do: Recovery.request(state, payload)

  defp apply_event(%{status: :ready} = state, %Event{
         source: :provider,
         type: :output_recovered,
         payload: %{token: token}
       }),
       do: Recovery.recovered(state, token)

  defp apply_event(%{status: :ready} = state, %Event{
         source: :provider,
         type: :output_interrupted,
         payload: %{token: token}
       }),
       do: Recovery.interrupted(state, token)

  defp apply_event(%{status: :ready} = state, %Event{
         source: :provider,
         type: :delegation_cancelled,
         payload: %{id: id}
       }) do
    case state.context.pending_delegations[id] do
      nil ->
        state

      %{status: :cancelled} ->
        state

      entry ->
        state = ContextWait.cancel(state, {:delegation, id})

        context = %{
          state.context
          | pending_delegations:
              Map.put(state.context.pending_delegations, id, %{entry | status: :cancelled})
        }

        state = State.revise(state, context)

        next = Jobs.cancel_delegation(state, id)

        Interpretation.start(next, %ContextTrigger{kind: :delegation_cancelled, delegation_id: id})
    end
  end

  defp apply_event(state, %Event{source: :channel, type: :playback_observed} = event),
    do: Progress.playback(state, event)

  defp apply_event(state, %Event{type: type, payload: %BackendResult{} = result})
       when type in [:request_completed, :request_failed, :request_cancelled] do
    Jobs.complete(state, result)
  end

  defp apply_event(state, %Event{source: :backend, type: :request_uncertain} = event),
    do:
      Uncertainty.mark(state, event.request_id, event.payload[:reason]) |> Jobs.deliver_pending()

  defp apply_event(state, %Event{
         source: :backend,
         type: :request_clarification,
         request_id: id,
         payload: payload
       }) do
    case state.jobs[id] do
      %{request: request} ->
        if State.current_result?(state, request) and
             payload.task_revision == request.task_revision do
          task = state.context.tasks[request.task_id] |> Map.put(:clarification, payload)

          state =
            State.revise(state, %{
              state.context
              | tasks: Map.put(state.context.tasks, request.task_id, task)
            })

          Interpretation.start(state, %ContextTrigger{
            kind: :backend_clarification,
            request_id: id,
            delegation_id: request.delegation_id
          })
        else
          state
        end

      nil ->
        state
    end
  end

  defp apply_event(state, %Event{
         source: :backend,
         type: type,
         request_id: id,
         command_id: command_id
       })
       when type in [:update_applied, :update_rejected] do
    case state.jobs[id] do
      %{pending_update: %{command_id: ^command_id, request: replacement}} = job ->
        job = Map.delete(job, :pending_update)
        job = if type == :update_applied, do: %{job | request: replacement}, else: job
        %{state | jobs: Map.put(state.jobs, id, job)}

      _other ->
        state
    end
  end

  defp apply_event(state, %Event{
         source: :backend,
         type: :request_progress,
         request_id: id,
         payload: payload
       }) do
    case state.jobs[id] do
      %{request: request} ->
        if State.current_result?(state, request) and
             payload.task_revision == request.task_revision do
          task = Map.put(state.context.tasks[request.task_id], :progress, payload)

          State.revise(state, %{
            state.context
            | tasks: Map.put(state.context.tasks, request.task_id, task)
          })
        else
          state
        end

      nil ->
        state
    end
  end

  defp apply_event(state, %Event{type: :usage_updated, payload: usage}),
    do: %{state | usage: usage}

  defp apply_event(state, %Event{type: :usage_final, payload: usage}),
    do: %{state | usage: usage, finalization: Map.get(usage, :complete?, true)}

  defp apply_event(state, %Event{type: :closed, source: role, payload: payload}) do
    state = %{state | closing_adapters: MapSet.put(state.closing_adapters, role)}

    state =
      if role == :provider,
        do: %{state | finalization: Map.get(payload, :finalized?, false)},
        else: state

    state = Shutdown.begin(state, :cancel)

    Shutdown.settle(state)
  end

  defp apply_event(state, %Event{type: type}) when type in [:failed, :disconnected],
    do: Shutdown.begin(state, :cancel)

  defp apply_event(state, _event), do: state

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid),
      do: state,
      else: %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
  end
end
