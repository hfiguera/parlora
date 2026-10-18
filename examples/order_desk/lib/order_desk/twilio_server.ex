defmodule OrderDesk.TwilioServer do
  @moduledoc "Signed phone-only public routes; the review application stays on a separate loopback listener."
  use Plug.Router
  alias Parlora.Channels.Twilio.Endpoint

  plug(:admit)
  plug(:match)
  plug(:dispatch)

  post "/twilio/voice" do
    config = Application.fetch_env!(:order_desk, :twilio)

    Endpoint.voice(conn,
      public_url: config.public_url <> "/twilio/voice",
      auth_token: config.auth_token,
      account_sid: config.account_sid,
      on_call: &OrderDesk.TwilioGate.issue/1
    )
  end

  get "/twilio/media/:ticket" do
    config = Application.fetch_env!(:order_desk, :twilio)

    Endpoint.upgrade(conn,
      public_url:
        String.replace_prefix(config.public_url, "https:", "wss:") <> "/twilio/media/" <> ticket,
      auth_token: config.auth_token,
      authorize: fn _conn -> authorize(config, ticket) end
    )
  end

  match(_, do: send_resp(conn, 404, "Not found"))

  def run do
    Logger.configure(level: :info)
    config = Application.fetch_env!(:order_desk, :twilio)
    validate!(config)
    actor = Parlora.ID.new()
    Application.put_env(:order_desk, :twilio_review_actor, actor)
    Application.put_env(:order_desk, :browser_origin, "http://localhost:#{config.review_port}")
    Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())
    Application.put_env(:order_desk, :browser_offline, false)

    {:ok, _gate} =
      Supervisor.start_child(
        OrderDesk.Supervisor,
        {OrderDesk.TwilioGate, public_url: config.public_url, phone_number: config.phone_number}
      )

    for {id, module, port} <- [
          {:twilio_http, __MODULE__, config.port},
          {:twilio_review, OrderDesk.BrowserServer, config.review_port}
        ] do
      spec =
        Supervisor.child_spec(
          {Bandit,
           plug: module,
           ip: {127, 0, 0, 1},
           port: port,
           thousand_island_options: [num_acceptors: 2, num_connections: 16, read_timeout: 5_000]},
          id: id
        )

      {:ok, _listener} = Supervisor.start_child(OrderDesk.Supervisor, spec)
    end

    IO.puts(
      "Twilio demo ready. Tunnel only port #{config.port}. Review: http://localhost:#{config.review_port}/phone-review"
    )

    IO.puts(
      "Use isolated demonstration data. Each call lasts at most 180 seconds. Caller ID does not authenticate a customer."
    )

    Process.sleep(:infinity)
  end

  defp authorize(config, ticket) do
    with {:ok, call} <- OrderDesk.TwilioGate.claim(ticket) do
      {:ok,
       [
         channel_options: [account_sid: config.account_sid, call_sid: call],
         start_session: fn channel ->
           OrderDesk.BrowserGate.start_session(
             channel,
             Application.fetch_env!(:order_desk, :twilio_review_actor),
             audio_format: Parlora.AudioFormat.pcmu()
           )
         end,
         on_ready: &OrderDesk.Greeting.start/1
       ]}
    end
  end

  defp admit(conn, _options) do
    case OrderDesk.TwilioGate.admit_request() do
      :ok -> conn
      _limited -> conn |> send_resp(429, "Too many requests") |> halt()
    end
  end

  defp validate!(config) do
    uri = URI.parse(config.public_url || "")

    unless uri.scheme == "https" and is_binary(uri.host) and uri.path in [nil, ""] and
             uri.port == 443 and
             uri.query == nil and uri.fragment == nil and uri.userinfo == nil,
           do: raise("TWILIO_PUBLIC_URL must be an HTTPS origin without a path or query")

    unless Enum.all?(
             [
               config.account_sid,
               config.auth_token,
               config.phone_number,
               OrderDesk.Provider.credential()
             ],
             &(is_binary(&1) and byte_size(&1) > 0)
           ),
           do: raise("Twilio and voice-provider runtime credentials are required")

    unless Process.whereis(OrderDesk.TypeSafe), do: raise("TYPESAFE_API_KEY is required")
  end
end
