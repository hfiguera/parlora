Code.require_file(System.fetch_env!("GROK_TRACE_SCRIPT"))
{:ok, _} = ParloraGrokCorrectionTrace.start(System.fetch_env!("GROK_TRACE_OUTPUT"))
# Test-only server and reset route; never loaded by application startup.
source = File.read!(Path.expand("../acceptance/server.exs", __DIR__))

[modules, _startup] =
  String.split(source, "unless System.get_env(\"PARLORA_ACCEPTANCE_LIVE\")", parts: 2)

Code.compile_string(modules)

defmodule ParloraTaskPilot.Server do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/__pilot/reset" do
    if OrderDesk.BrowserGate.count() == 0 and
         DynamicSupervisor.count_children(Parlora.Sessions).active == 0 do
      path =
        Path.join(
          System.fetch_env!("PILOT_OUTPUT"),
          "case-#{System.unique_integer([:positive])}.sqlite3"
        )

      :ok = Supervisor.terminate_child(OrderDesk.Supervisor, OrderDesk.Store)
      :ok = Supervisor.delete_child(OrderDesk.Supervisor, OrderDesk.Store)
      {:ok, _} = Supervisor.start_child(OrderDesk.Supervisor, {OrderDesk.Store, path: path})
      :ok = Supervisor.terminate_child(OrderDesk.Supervisor, OrderDesk.Interpretation)
      {:ok, _} = Supervisor.restart_child(OrderDesk.Supervisor, OrderDesk.Interpretation)
      :sys.replace_state(ParloraAcceptance.Observer, fn _ -> %{} end)
      json(conn, %{database: Path.basename(path)})
    else
      send_resp(conn, 409, "Sessions still active")
    end
  end

  get "/__pilot/interpretation" do
    json(conn, %{
      evidence: OrderDesk.Interpretation.evidence(),
      stats: OrderDesk.Interpretation.stats()
    })
  end

  post "/__pilot/order-numbers" do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 16_384)
    text = Jason.decode!(body)["text"]
    json(conn, %{numbers: OrderDesk.Speech.numbers(text)})
  end

  get "/__pilot/provider-diagnostics/:id" do
    if Process.whereis(ParloraSilentSession.Collector) do
      json(conn, GenServer.call(ParloraSilentSession.Collector, {:report, id}))
    else
      send_resp(conn, 404, "Diagnostics disabled")
    end
  end

  match _ do
    ParloraAcceptance.Server.call(conn, ParloraAcceptance.Server.init([]))
  end

  defp json(conn, data),
    do: send_resp(put_resp_content_type(conn, "application/json"), 200, Jason.encode!(data))
end

unless System.get_env("PARLORA_ACCEPTANCE_LIVE") == "1", do: raise("Live opt-in required")
Logger.configure(level: :warning)

if path = System.get_env("PARLORA_STALL_TRACE_PATH") do
  Code.require_file(Path.expand("../gemini/stall-investigation/trace.exs", __DIR__))
  {:ok, _} = ParloraGeminiStallTrace.start(path)
end

slow_lookup = if System.get_env("PILOT_SLOW_CORRECTION") == "1", do: 12_000, else: 4_000

Application.put_env(:order_desk, :lookup_delays, %{
  "123" => slow_lookup,
  "124" => 1_000,
  "825" => 1_000
})

port = System.fetch_env!("PORT") |> String.to_integer()
Application.put_env(:order_desk, :browser_origin, "http://127.0.0.1:#{port}")
Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())
Application.put_env(:order_desk, :browser_offline, false)

if System.get_env("PILOT_DIAGNOSTICS") == "1" do
  Code.require_file(Path.expand("../silent-session/collector.exs", __DIR__))

  {:ok, sink} =
    ParloraSilentSession.Collector.start_link(
      Path.join(System.fetch_env!("PILOT_OUTPUT"), "provider")
    )

  Application.put_env(:order_desk, :provider_diagnostic_sink, sink)
end

if System.get_env("PILOT_INTERPRETATION_DIAGNOSTICS") == "1" do
  Code.require_file(Path.expand("../interpretation-timeout/collector.exs", __DIR__))
  {:ok, _} = ParloraInterpretationTrace.start_link(System.fetch_env!("PILOT_OUTPUT"))
end

{:ok, _} = ParloraAcceptance.Observer.start_link([])

:ok =
  :telemetry.attach("task-pilot", [:parlora, :event], &ParloraAcceptance.Observer.ready/4, nil)

{:ok, _} = Bandit.start_link(plug: ParloraTaskPilot.Server, ip: {127, 0, 0, 1}, port: port)
IO.puts("PILOT_READY")
Process.sleep(:infinity)
