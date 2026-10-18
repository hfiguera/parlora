# Dedicated loopback-only acceptance server. Never loaded by the normal application.
defmodule ParloraTwilioAcceptance.Observer do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def init(state), do: {:ok, state}

  def ready(_event, _measurements, %{source: :session, type: :ready}, _) do
    send(__MODULE__, {:watch, self()})
  end

  def ready(_, _, _, _), do: :ok

  def handle_info({:watch, pid}, state) do
    :ok = Parlora.subscribe(pid)
    snapshot = Parlora.snapshot(pid)
    Process.monitor(pid)

    entry = %{
      pid: pid,
      started: System.monotonic_time(:microsecond),
      closed: false,
      jobs: %{},
      playback: %{},
      audio_peaks: %{},
      events: [],
      snapshot: snapshot,
      status: Parlora.status(pid)
    }

    {:noreply, Map.put(state, snapshot.session_id, entry)}
  end

  def handle_info({:parlora_event, %{type: :playback_observed} = event}, state) do
    case state[event.session_id] do
      nil ->
        {:noreply, state}

      entry ->
        stage = event.payload.stage
        playback = Map.update(entry.playback, stage, 1, &(&1 + 1))

        peaks =
          Enum.reduce(
            [:queued_bytes, :inflight_bytes, :ack_latency_us, :queue_age_us],
            entry.audio_peaks,
            fn key, peaks ->
              case event.payload do
                %{^key => value} when is_number(value) ->
                  Map.update(peaks, key, value, &max(&1, value))

                _ ->
                  peaks
              end
            end
          )

        {:noreply,
         Map.put(state, event.session_id, %{entry | playback: playback, audio_peaks: peaks})}
    end
  end

  def handle_info({:parlora_event, %{type: type} = event}, state)
      when type in [
             :task_submitted,
             :request_started,
             :request_completed,
             :result_delivery,
             :delegation_pending,
             :delegation_associated,
             :context_wait_started,
             :clarification_requested,
             :closed,
             :failed,
             :transcript_delta,
             :context_acknowledged,
             :context_rejected,
             :audio_discontinuity,
             :control_completed,
             :control_failed
           ] do
    case state[event.session_id] do
      nil ->
        {:noreply, state}

      entry ->
        jobs =
          if event.type == :task_submitted do
            r = event.payload.request

            Map.put(entry.jobs, r.id, %{
              id: r.id,
              task_id: r.task_id,
              revision: r.task_revision,
              input: Map.take(r.input, [:order, :operation, :instructions])
            })
          else
            entry.jobs
          end

        info = %{
          type: event.type,
          source: event.source,
          request_id: event.request_id,
          command_id: event.command_id,
          observed_at_us: event.observed_at_us,
          payload: safe_payload(event.payload)
        }

        entry = %{entry | jobs: jobs, events: Enum.take([info | entry.events], 1000)}
        {:noreply, Map.put(state, event.session_id, refresh(entry))}
    end
  end

  def handle_info({:DOWN, _, :process, pid, _}, state) do
    {:noreply,
     Map.new(state, fn {id, e} -> {id, if(e.pid == pid, do: %{e | closed: true}, else: e)} end)}
  end

  def handle_info(_, state), do: {:noreply, state}

  def handle_call({:control, session_id, operation}, _from, state) do
    id = Parlora.ID.new()

    control =
      case operation do
        "clear" -> {:clear_output, :next}
        "suppress" -> {:suppress_output, true}
        "resume" -> {:suppress_output, false}
      end

    reply =
      case state[session_id] do
        %{closed: false, pid: pid} ->
          case Parlora.control(pid, control, id) do
            :ok -> {:ok, id}
            _ -> {:error, :control_failed}
          end

        _ ->
          {:error, :no_session}
      end

    {:reply, reply, state}
  end

  def handle_call(:state, _, state) do
    state = Map.new(state, fn {id, entry} -> {id, refresh(entry)} end)

    data =
      Map.new(state, fn {id, e} ->
        {id,
         %{
           started: e.started,
           closed: e.closed,
           jobs: e.jobs,
           playback: e.playback,
           audio_peaks: e.audio_peaks,
           events: Enum.reverse(e.events),
           status: e.status,
           tasks:
             Map.new(e.snapshot.tasks, fn {task_id, task} ->
               {task_id, Map.take(task, [:input, :revision, :status])}
             end)
         }}
      end)

    {:reply, data, state}
  end

  defp safe_payload(payload) do
    selected =
      Map.take(payload, [
        :stage,
        :cause,
        :delta,
        :speaker,
        :evidence,
        :boundary,
        :reason,
        :scope,
        :finalized?,
        :usage
      ])

    case Map.get(payload, :error) do
      %{code: code, message: message} ->
        Map.put(selected, :error, %{code: code, message: message})

      _ ->
        selected
    end
  end

  defp refresh(%{closed: true} = entry), do: entry

  defp refresh(entry) do
    try do
      with %Parlora.ContextSnapshot{} = snapshot <- Parlora.snapshot(entry.pid),
           %{session_id: _} = status <- Parlora.status(entry.pid) do
        %{entry | snapshot: snapshot, status: status}
      else
        _closed -> %{entry | closed: true}
      end
    catch
      :exit, _ -> %{entry | closed: true}
    end
  end
end
