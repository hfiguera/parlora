# Validation-only fixed-destination caller route. Not part of the consumer or package.
Code.require_file("observer.exs", __DIR__)

defmodule ParloraTwilioAcceptance.Public do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/__test/dial" do
    config = Application.fetch_env!(:order_desk, :twilio)

    with {:ok, body, conn} <- read_body(conn, length: 16_384, read_timeout: 1_000),
         params = URI.decode_query(body),
         :ok <-
           Parlora.Channels.Twilio.Signature.verify(
             conn,
             config.auth_token,
             config.public_url <> "/__test/dial",
             params
           ),
         true <- params["ScenarioToken"] == System.fetch_env!("TWILIO_TEST_NONCE") do
      number = config.phone_number

      xml =
        "<Response><Dial callerId=\"#{number}\" timeLimit=\"120\" timeout=\"20\"><Number>#{number}</Number></Dial><Hangup/></Response>"

      conn |> put_resp_content_type("text/xml") |> send_resp(200, xml)
    else
      _ -> send_resp(conn, 403, "Forbidden")
    end
  end

  match _ do
    if String.starts_with?(conn.request_path, "/twilio/media/") do
      config = Application.fetch_env!(:order_desk, :twilio)
      signature = List.first(get_req_header(conn, "x-twilio-signature")) || ""
      url = config.public_url <> conn.request_path

      checks =
        for {name, candidate} <- [
              https: url,
              https_slash: url <> "/",
              wss: String.replace_prefix(url, "https:", "wss:"),
              wss_slash: String.replace_prefix(url, "https:", "wss:") <> "/"
            ],
            into: %{} do
          {name,
           Parlora.Channels.Twilio.Signature.valid?(config.auth_token, candidate, %{}, signature)}
        end

      IO.puts(Jason.encode!(%{handshake_signature_candidates: checks}))
    end

    result = OrderDesk.TwilioServer.call(conn, OrderDesk.TwilioServer.init([]))

    IO.puts(
      Jason.encode!(%{
        route: if(conn.method == "POST", do: "voice", else: "stream"),
        status: result.status
      })
    )

    result
  end
end

defmodule ParloraTwilioAcceptance.Private do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  get "/__acceptance/state" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(GenServer.call(ParloraTwilioAcceptance.Observer, :state)))
  end

  post "/__acceptance/control" do
    with {:ok, body, conn} <- read_body(conn, length: 1024),
         {:ok, %{"session_id" => session, "operation" => operation}} <- Jason.decode(body),
         true <- operation in ["clear", "suppress", "resume"],
         {:ok, id} <-
           GenServer.call(ParloraTwilioAcceptance.Observer, {:control, session, operation}) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{command_id: id}))
    else
      _ -> send_resp(conn, 400, "Control rejected")
    end
  end

  match _ do
    OrderDesk.BrowserServer.call(conn, OrderDesk.BrowserServer.init([]))
  end
end

unless System.get_env("PARLORA_ACCEPTANCE_LIVE") == "1", do: raise("Live opt-in required")
Logger.configure(level: :warning)
config = Application.fetch_env!(:order_desk, :twilio)
Application.put_env(:order_desk, :lookup_delays, %{"123" => 8_000, "124" => 4_000})
Application.put_env(:order_desk, :twilio_review_actor, Parlora.ID.new())
Application.put_env(:order_desk, :browser_origin, "http://localhost:#{config.review_port}")
Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())
Application.put_env(:order_desk, :browser_offline, false)
{:ok, _} = ParloraTwilioAcceptance.Observer.start_link([])

:ok =
  :telemetry.attach(
    "twilio-live-observer",
    [:parlora, :event],
    &ParloraTwilioAcceptance.Observer.ready/4,
    nil
  )

{:ok, _} =
  OrderDesk.TwilioGate.start_link(
    public_url: config.public_url,
    phone_number: config.phone_number
  )

for {plug, port} <- [
      {ParloraTwilioAcceptance.Public, config.port},
      {ParloraTwilioAcceptance.Private, config.review_port}
    ] do
  {:ok, _} =
    Bandit.start_link(
      plug: plug,
      ip: {127, 0, 0, 1},
      port: port,
      thousand_island_options: [num_acceptors: 2, num_connections: 16, read_timeout: 5_000]
    )
end

IO.puts("TWILIO_ACCEPTANCE_READY")
Process.sleep(:infinity)
