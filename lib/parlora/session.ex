defmodule Parlora.Session do
  @moduledoc false
  use GenServer

  alias Parlora.{
    Adapter,
    AdapterOwner,
    AudioPipeline,
    BackendResult,
    ContextTrigger,
    ContextUpdate,
    Error,
    Event,
    ID,
    Telemetry
  }

  alias Parlora.Session.{Commands, ContextWait, Decisions, Health, Progress, State, Uncertainty}
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
  def handle_continue(:start_adapters, state) do
    Process.send_after(self(), :startup_timeout, state.limits.startup_timeout_ms)
    deadline = System.monotonic_time(:microsecond) + state.limits.startup_timeout_ms * 1_000

    {:noreply,
     start_adapter(%{state | startup: %{state.startup | deadline_us: deadline}}, :channel)}
  end

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
    {:reply, reply, health_update(state, health)}
  end

  def handle_call({:resolve_progress, id, outcome}, _from, %{status: :ready} = state) do
    {reply, health} = Health.resolve(state.health, id, outcome)
    {:reply, reply, health_update(state, health)}
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

  def handle_call({:cancel, id, request_id, reason}, from, %{status: :ready} = state) do
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

  def handle_call({:context, context}, _from, %{status: :ready} = state) when is_map(context) do
    state = State.revise(state, %{state.context | application_context: context})
    {:reply, :ok, interpret(state, %ContextTrigger{kind: :application_context_updated})}
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
    {:reply, :ok, begin_close(state, policy)}
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
    state = %{
      state
      | adapters: Map.put(state.adapters, role, {module, pid}),
        startup: %{state.startup | pending: nil}
    }

    next =
      case role do
        :channel -> start_adapter(state, :provider)
        :provider -> start_adapter(state, :backend)
        :backend -> maybe_start_audio(state)
      end

    {:noreply, next}
  end

  def handle_info(
        {:parlora_adapter_failed, owner, reason},
        %{status: :starting, startup: %{pending: %{owner: owner}}} = state
      ),
      do: {:noreply, startup_failed(state, reason)}

  def handle_info(
        {:parlora_pipeline_ready, pid, token},
        %{status: :starting, startup: %{pipeline_token: token}} = state
      )
      when is_reference(token) do
    pending = MapSet.delete(state.startup.pending_pipelines, pid)
    state = %{state | startup: %{state.startup | pending_pipelines: pending}}
    {:noreply, if(MapSet.size(pending) == 0, do: complete_startup(state), else: state)}
  end

  def handle_info({:context_wait, key, token}, %{status: :ready} = state) do
    {state, trigger} = ContextWait.expire(state, key, token)
    {:noreply, if(trigger, do: interpret(state, trigger), else: state)}
  end

  def handle_info({:parlora_event, %Event{source: :session} = event}, state) do
    {:noreply, State.broadcast(state, event)}
  end

  def handle_info({:parlora_event, %Event{} = event}, state) do
    if current_adapter?(state, event) do
      state = State.broadcast(state, event)
      state = health_update(state, Health.observe(state.health, event))
      {:noreply, apply_event(state, event)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:progress_deadline, token}, %{status: :ready} = state) do
    {action, health} = Health.expire(state.health, token)
    state = health_update(state, health)

    if action == :close do
      State.emit(state, :failed, %{
        cause: :progress_timeout,
        health: Health.snapshot(state.health),
        error: Error.new(:timeout, "Expected session progress was not observed")
      })

      {:noreply, begin_close(state, :cancel)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{policy_task: %{ref: ref} = work} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(work.timer)
    outcome = if match?({:ok, _}, result), do: :ok, else: :error

    outcome =
      if match?({:ok, _}, result) and state.context.revision != work.revision,
        do: :superseded,
        else: outcome

    Telemetry.stop(work.telemetry, outcome)
    state = %{state | policy_task: nil}

    next =
      if state.status == :ready and
           (state.context.revision == work.revision or not match?({:ok, _}, result)) do
        apply_policy(state, result)
      else
        interpret(state, state.policy_trigger)
      end

    {:noreply, deliver_pending(next)}
  end

  def handle_info({:policy_timeout, ref}, %{policy_task: %{ref: ref} = work} = state) do
    Telemetry.stop(work.telemetry, :timeout)
    Task.Supervisor.terminate_child(SessionSupervisor.via(state.id, :tasks), work.pid)
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(work.timer)

    {:noreply,
     policy_failed(
       %{state | policy_task: nil},
       Error.new(:timeout, "Context policy deadline expired")
     )}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{policy_task: %{ref: ref} = work} = state
      ) do
    Process.cancel_timer(work.timer)
    Telemetry.stop(work.telemetry, :error)

    {:noreply,
     policy_failed(
       %{state | policy_task: nil},
       Error.new(:adapter_failed, "Context policy exited")
     )}
  end

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

        {:noreply, state |> begin_close(:cancel) |> finish_close_if_settled()}
    end
  end

  def handle_info({:parlora_command_result, reference, reply}, state),
    do:
      {:noreply,
       Commands.result(state, reference, reply)
       |> deliver_pending()
       |> Decisions.dispatch_pending()}

  def handle_info({:adapter_command_timeout, reference}, state) do
    {next, stalled?} = Commands.timeout(state, reference)

    if stalled?,
      do:
        State.emit(next, :failed, %{
          error: Error.new(:timeout, "Adapter command stalled; admission is uncertain")
        })

    {:noreply, if(stalled?, do: begin_close(next, :cancel), else: next)}
  end

  def handle_info(:startup_timeout, %{status: :starting} = state) do
    {:noreply, startup_failed(state, :timeout)}
  end

  def handle_info({:parlora_process_stopped, worker}, %{status: :closing} = state) do
    state = %{
      state
      | startup: %{state.startup | cleanup: MapSet.delete(state.startup.cleanup, worker)}
    }

    {:noreply, finish_close_if_settled(state)}
  end

  def handle_info({:cancellation_deadline, id, request_id}, state) do
    case state.jobs[request_id] do
      %{status: status} when status in [:completed, :failed, :cancelled] ->
        :ok

      _pending ->
        State.emit(state, :cancellation_unconfirmed, %{outcome: :unknown},
          command_id: id,
          request_id: request_id
        )
    end

    {:noreply, state}
  end

  def handle_info({:job_deadline, id}, state) do
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
        {:noreply, complete_job(state, result) |> Commands.cancel({:submit, id})}

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

        {:noreply, Uncertainty.mark(state, id, :job_deadline) |> deliver_pending()}

      _terminal_or_unknown ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) when message in [:shutdown_timeout, :shutdown_settled] do
    terminate_policy(state)
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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
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
    terminate_policy(state)
    Telemetry.stop(state.startup.telemetry_session, outcome)
  end

  defp start_adapter(state, role) do
    if System.monotonic_time(:microsecond) < state.startup.deadline_us,
      do: start_adapter_owner(state, role),
      else: startup_failed(state, :timeout)
  end

  defp start_adapter_owner(state, role) do
    {module, options} = Keyword.fetch!(state.options, role)
    options = if role == :provider, do: provider_options(options, state.options), else: options

    init = %{
      state.init
      | adapter_id: ID.new(),
        audio_format: if(role == :backend, do: nil, else: state.init.audio_format)
    }

    deadline = state.startup.deadline_us

    spec = %{
      id: init.adapter_id,
      start: {AdapterOwner, :start_link, [fn -> {module, init, options, deadline} end]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(SessionSupervisor.via(state.id, :adapters), spec) do
      {:ok, owner, watcher} ->
        ref = Process.monitor(owner)

        %{
          state
          | startup: %{
              state.startup
              | pending: %{role: role, owner: owner, module: module, watcher: watcher},
                owners: Map.put(state.startup.owners, role, %{owner: owner, watcher: watcher})
            },
            monitors: Map.put(state.monitors, ref, role),
            options: Keyword.put(state.options, role, {init, []})
        }

      {:error, _reason} ->
        startup_failed(state, :adapter_failed)
    end
  end

  defp startup_failed(state, reason) do
    message =
      if reason == :timeout,
        do: "Session readiness deadline expired",
        else: "Adapter startup failed"

    Telemetry.stop(
      state.startup.telemetry_startup,
      if(reason == :timeout, do: :timeout, else: :failed)
    )

    state = %{state | startup: %{state.startup | telemetry_startup: nil}}
    State.emit(state, :failed, %{error: Error.new(reason, message)})
    begin_close(state, :cancel)
  end

  defp abort_startup(%{status: :starting} = state) do
    Enum.each(state.startup.owners, fn {_role, owner} -> AdapterOwner.cancel(owner.watcher) end)
  end

  defp abort_startup(_state), do: :ok

  defp provider_options(options, session_options) do
    Keyword.merge(Keyword.take(session_options, [:instructions, :history]), options)
  end

  defp current_adapter?(state, event) do
    case Keyword.get(state.options, event.source) do
      {%Parlora.AdapterInit{adapter_id: id, generation: generation}, _options} ->
        event.adapter_id == id and event.generation == generation

      _other ->
        false
    end
  end

  defp apply_event(state, %Event{type: :ready, source: role, payload: payload}) do
    state = %{state | ready: Map.put(state.ready, role, payload.capabilities)}

    maybe_start_audio(state)
  end

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

      interpret(state, %ContextTrigger{kind: :transcript_updated})
    else
      State.emit(state, :failed, %{
        error: Error.new(:backpressure, "Transcript capacity exhausted")
      })

      begin_close(state, :cancel)
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
        interpret(state, %ContextTrigger{kind: :delegation, delegation_id: payload.id})
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
         payload: %{token: token} = payload
       }) do
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
      begin_close(state, :cancel)
    end
  end

  defp apply_event(%{output_recovery: %{token: token}} = state, %Event{
         source: :provider,
         type: :output_recovered,
         payload: %{token: token}
       }) do
    Telemetry.stop(state.output_recovery.telemetry, :reconnected)
    # The adapter's connection incarnation changed. Tasks and their revision /
    # execution identity did not; no backend submit or retry occurs here.
    %{
      state
      | output_recovery:
          state.output_recovery |> Map.put(:stage, :awaiting_user) |> Map.delete(:telemetry)
    }
  end

  defp apply_event(%{status: :ready} = state, %Event{
         source: :provider,
         type: :output_interrupted,
         payload: %{token: token}
       }) do
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
      begin_close(state, :cancel)
    end
  end

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

        next = Enum.reduce(state.jobs, state, &cancel_delegated_job(&1, &2, id))

        interpret(next, %ContextTrigger{kind: :delegation_cancelled, delegation_id: id})
    end
  end

  defp apply_event(state, %Event{source: :channel, type: :playback_observed} = event),
    do: Progress.playback(state, event)

  defp apply_event(state, %Event{type: type, payload: %BackendResult{} = result})
       when type in [:request_completed, :request_failed, :request_cancelled] do
    complete_job(state, result)
  end

  defp apply_event(state, %Event{source: :backend, type: :request_uncertain} = event),
    do: Uncertainty.mark(state, event.request_id, event.payload[:reason]) |> deliver_pending()

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

          interpret(state, %ContextTrigger{
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

    state = begin_close(state, :cancel)

    finish_close_if_settled(state)
  end

  defp apply_event(state, %Event{type: type}) when type in [:failed, :disconnected],
    do: begin_close(state, :cancel)

  defp apply_event(state, _event), do: state

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
      if(reply == :ok, do: current, else: begin_close(current, :cancel))
    end

    case Commands.enqueue(state, :provider, callback, complete) do
      {:ok, next} ->
        next

      _error ->
        Telemetry.stop(telemetry, :rejected)
        begin_close(state, :cancel)
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
    pending? = Map.has_key?(state.startup.commands.keys, {:cancel, id})

    pending =
      Enum.count(state.startup.commands.keys, fn
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

      state = complete_job(state, result) |> Commands.cancel({:submit, request_id})

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

  defp start_audio(state) do
    state = %{state | startup: %{state.startup | pipeline_token: make_ref()}}

    with :ok <- validate_capabilities(state),
         {:ok, input} <-
           start_pipeline(state, :input, state.adapters.channel, state.adapters.provider),
         {:ok, output} <-
           start_pipeline(state, :output, state.adapters.provider, state.adapters.channel) do
      monitors =
        state.monitors
        |> Map.put(Process.monitor(input), :input_pipeline)
        |> Map.put(Process.monitor(output), :output_pipeline)

      %{
        state
        | input_pipeline: input,
          output_pipeline: output,
          startup: %{state.startup | pending_pipelines: MapSet.new([input, output])},
          monitors: monitors
      }
    else
      {:error, error} ->
        State.emit(state, :failed, %{error: error})
        begin_close(state, :cancel)
    end
  end

  defp maybe_start_audio(
         %{status: :starting, input_pipeline: nil, adapters: adapters, ready: ready} = state
       )
       when map_size(adapters) == 3 and map_size(ready) == 3 do
    if System.monotonic_time(:microsecond) < state.startup.deadline_us,
      do: start_audio(state),
      else: startup_failed(state, :timeout)
  end

  defp maybe_start_audio(state), do: state

  defp complete_startup(state) do
    if System.monotonic_time(:microsecond) < state.startup.deadline_us do
      Telemetry.stop(state.startup.telemetry_startup, :ready)
      State.emit(state, :ready, %{capabilities: state.ready})

      Enum.each([state.input_pipeline, state.output_pipeline], fn pid ->
        send(pid, {:activate_pipeline, state.startup.pipeline_token})
      end)

      %{state | status: :ready, startup: %{state.startup | telemetry_startup: nil}}
    else
      startup_failed(state, :timeout)
    end
  end

  defp validate_capabilities(state) do
    format = state.init.audio_format
    channel = state.ready.channel
    provider = state.ready.provider

    if format in channel.input_formats and format in channel.output_formats and
         channel.output_pacing in [:pipeline, :channel] and
         format in provider.audio_formats and channel.full_duplex? and provider.full_duplex? and
         :client in provider.delegation_modes and :speakable in provider.context_update_kinds do
      :ok
    else
      Error.tuple(
        :unsupported,
        "Adapters do not support the required full-duplex client-delegation path"
      )
    end
  end

  defp start_pipeline(state, direction, source, destination) do
    options = [
      init: state.init,
      startup_owner: self(),
      startup_token: state.startup.pipeline_token,
      direction: direction,
      source: source,
      destination: destination,
      health_counters: state.health.audio,
      output_pacing: state.ready.channel.output_pacing
    ]

    spec = %{
      id: direction,
      start: {AudioPipeline, :start_link, [options]},
      restart: :temporary,
      shutdown: :brutal_kill
    }

    DynamicSupervisor.start_child(SessionSupervisor.via(state.id, :adapters), spec)
  end

  defp interpret(%{status: :ready, policy_task: nil} = state, trigger) do
    {module, options} = state.policy
    snapshot = state.context

    telemetry =
      Telemetry.start(:policy, %{
        session_id: state.id,
        parent_operation_id: state.startup.telemetry_session.metadata.operation_id
      })

    task =
      Task.Supervisor.async_nolink(
        SessionSupervisor.via(state.id, :tasks),
        fn -> module.interpret(snapshot, trigger, options) end,
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

  defp interpret(state, trigger), do: %{state | policy_trigger: trigger, context_resolved?: false}

  defp apply_policy(state, {:ok, decisions}) do
    case Decisions.apply_batch(state, decisions) do
      {:ok, next} ->
        unresolved =
          Enum.any?(
            decisions,
            &(&1.kind in [:wait_for_context, :request_clarification] and is_binary(&1.task_id))
          )

        %{next | context_resolved?: not unresolved, policy_failures: 0}

      {:error, error} ->
        State.emit(state, :policy_rejected, %{error: error})

        if error.code == :backpressure and
             Enum.any?(decisions, &(&1.kind in [:supersede_task, :update_task])),
           do: begin_close(state, :cancel),
           else: state
    end
  end

  defp apply_policy(state, _error),
    do: policy_failed(state, Error.new(:adapter_failed, "Context policy failed"))

  defp policy_failed(%{status: status} = state, _error) when status != :ready, do: state

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
      interpret(state, state.policy_trigger)
    else
      State.emit(state, :failed, %{
        cause: :policy_failed,
        error: Error.new(:adapter_failed, "Context interpretation failed after one retry")
      })

      begin_close(state, :cancel)
    end
  end

  defp complete_job(state, result) do
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

  defp deliver_pending(
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

  defp deliver_pending(state), do: state

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

  defp begin_close(%{status: :closing} = state, _policy), do: state

  defp begin_close(state, policy) do
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
    timer = Process.send_after(self(), :shutdown_timeout, state.limits.shutdown_timeout_ms)
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
    state = health_update(state, Health.close(state.health))

    cleanup =
      [
        terminate_policy(state, self())
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

    finish_close_if_settled(%{
      state
      | status: :closing,
        shutdown_timer: timer,
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

  defp finish_close_if_settled(state) do
    if MapSet.size(state.startup.cleanup) == 0 and
         Enum.all?(Map.keys(state.startup.owners), &MapSet.member?(state.closing_adapters, &1)),
       do: send(self(), :shutdown_settled)

    state
  end

  defp health_update(state, health) do
    if state.health.expectation != health.expectation,
      do: State.emit(state, :progress_changed, health.expectation)

    %{state | health: health}
  end

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid),
      do: state,
      else: %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
  end

  defp terminate_policy(state, notify \\ nil)

  defp terminate_policy(%{policy_task: nil}, _notify), do: nil

  defp terminate_policy(state, notify) do
    Telemetry.stop(state.policy_task.telemetry, :cancelled)
    Process.cancel_timer(state.policy_task.timer)
    Process.demonitor(state.policy_task.ref, [:flush])
    AdapterOwner.stop(state.policy_task.pid, notify)
  end

  defp job_outcomes(state) do
    Map.new(state.jobs, fn {id, job} ->
      outcome = if job.status == :submitted, do: :uncertain, else: job.status
      {id, outcome}
    end)
  end
end
