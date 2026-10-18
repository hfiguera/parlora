# Dedicated loopback-only acceptance server. Never loaded by the normal application.
defmodule ParloraAcceptance.Observer do
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
      events: [],
      snapshot: snapshot,
      status: Parlora.status(pid)
    }

    {:noreply, Map.put(state, snapshot.session_id, entry)}
  end

  def handle_info({:parlora_event, %{type: type} = event}, state)
      when type in [
             :context_acknowledged,
             :context_submitted,
             :provider_activity,
             :provider_speech,
             :provider_connection,
             :output_interrupted,
             :delegation_cancelled,
             :usage_updated,
             :usage_final,
             :progress_changed,
             :task_submitted,
             :request_started,
             :request_completed,
             :result_delivery,
             :delegation_pending,
             :delegation_associated,
             :context_wait_started,
             :clarification_requested,
             :closed,
             :failed
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
          observed_at_us: event.observed_at_us,
          payload:
            Map.take(event.payload, [
              :stage,
              :cause,
              :health,
              :status,
              :id,
              :until,
              :on_timeout,
              :state,
              :token,
              :unit,
              :scope,
              :values,
              :report,
              :seconds,
              :final?,
              :context_window,
              :outcome,
              :evidence
            ])
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

  def handle_call(:state, _, state) do
    state = Map.new(state, fn {id, entry} -> {id, refresh(entry)} end)

    data =
      Map.new(state, fn {id, e} ->
        {id,
         %{
           started: e.started,
           closed: e.closed,
           jobs: e.jobs,
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

defmodule ParloraAcceptance.Server do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/__acceptance/state" do
    send_resp(
      put_resp_content_type(conn, "application/json"),
      200,
      Jason.encode!(GenServer.call(ParloraAcceptance.Observer, :state))
    )
  end

  match _ do
    OrderDesk.BrowserServer.call(conn, OrderDesk.BrowserServer.init([]))
  end
end

unless System.get_env("PARLORA_ACCEPTANCE_LIVE") == "1",
  do: raise("Acceptance live opt-in required")

Logger.configure(level: :warning)
Application.put_env(:order_desk, :lookup_delays, %{"123" => 8_000, "124" => 4_000})
port = System.fetch_env!("PORT") |> String.to_integer()
Application.put_env(:order_desk, :browser_origin, "http://127.0.0.1:#{port}")
Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())
Application.put_env(:order_desk, :browser_offline, false)
{:ok, _} = ParloraAcceptance.Observer.start_link([])

:ok =
  :telemetry.attach(
    "parlora-acceptance",
    [:parlora, :event],
    &ParloraAcceptance.Observer.ready/4,
    nil
  )

{:ok, _} = Bandit.start_link(plug: ParloraAcceptance.Server, ip: {127, 0, 0, 1}, port: port)
IO.puts("ACCEPTANCE_READY")
Process.sleep(:infinity)
