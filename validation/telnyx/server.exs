# Validation-only Twilio SDK caller to the fixed Telnyx development number.
defmodule ParloraTelnyxAcceptance.Public do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/__test/dial" do
    twilio = Application.fetch_env!(:order_desk, :twilio)
    telnyx = Application.fetch_env!(:order_desk, :telnyx)

    with {:ok, body, conn} <- read_body(conn, length: 16_384, read_timeout: 1_000),
         params = URI.decode_query(body),
         :ok <-
           Parlora.Channels.Twilio.Signature.verify(
             conn,
             twilio.auth_token,
             telnyx.public_url <> "/__test/dial",
             params
           ),
         true <- params["ScenarioToken"] == System.fetch_env!("TWILIO_TEST_NONCE") do
      xml =
        "<Response><Dial callerId=\"#{twilio.phone_number}\" timeLimit=\"120\" timeout=\"20\"><Number>#{telnyx.phone_number}</Number></Dial><Hangup/></Response>"

      conn |> put_resp_content_type("text/xml") |> send_resp(200, xml)
    else
      _invalid -> send_resp(conn, 403, "Forbidden")
    end
  end

  match _ do
    result = OrderDesk.TelnyxServer.call(conn, OrderDesk.TelnyxServer.init([]))

    IO.puts(
      Jason.encode!(%{
        route: if(conn.method == "POST", do: "webhook", else: "media"),
        status: result.status
      })
    )

    result
  end
end

defmodule ParloraTelnyxAcceptance.Private do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  # Private development listener only. Caller text must not reach public routes.
  get "/__acceptance/interpretations" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(OrderDesk.Interpretation.evidence()))
  end

  get "/__acceptance/state" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(OrderDesk.PhoneDiagnostics.snapshot()))
  end

  get "/__acceptance/calls" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(OrderDesk.TelnyxGate.observations()))
  end

  post "/__acceptance/control" do
    with {:ok, body, conn} <- read_body(conn, length: 1024),
         {:ok, %{"session_id" => id, "operation" => operation}} <- Jason.decode(body),
         {:ok, command_id} <- OrderDesk.PhoneDiagnostics.control(id, operation) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{command_id: command_id}))
    else
      _invalid -> send_resp(conn, 400, "Control rejected")
    end
  end

  match _ do
    OrderDesk.BrowserServer.call(conn, OrderDesk.BrowserServer.init([]))
  end
end

unless System.get_env("PARLORA_ACCEPTANCE_LIVE") == "1", do: raise("Live opt-in required")
Application.put_env(:order_desk, :lookup_delays, %{"123" => 8_000, "124" => 4_000})

OrderDesk.TelnyxServer.start(
  public_plug: ParloraTelnyxAcceptance.Public,
  private_plug: ParloraTelnyxAcceptance.Private
)

IO.puts("TELNYX_ACCEPTANCE_READY")
Process.sleep(:infinity)
