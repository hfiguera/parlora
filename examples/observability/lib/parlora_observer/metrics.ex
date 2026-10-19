defmodule ParloraObserver.Metrics do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape())
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
