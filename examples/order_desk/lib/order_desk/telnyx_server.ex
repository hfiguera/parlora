defmodule OrderDesk.TelnyxServer do
  @moduledoc "Telnyx phone routes; the application review UI stays on a private loopback listener."
  use Plug.Router
  alias Parlora.Channels.Telnyx.Endpoint
  alias OrderDesk.TelnyxGate

  plug(:admit)
  plug(:match)
  plug(:dispatch)

  post "/telnyx/events" do
    config = Application.fetch_env!(:order_desk, :telnyx)
    Endpoint.webhook(conn, public_key: config.public_key, on_event: &TelnyxGate.event/1)
  end

  get "/telnyx/media/:ticket" do
    Endpoint.upgrade(conn, authorize: fn _conn, token -> authorize(ticket, token) end)
  end

  match(_, do: send_resp(conn, 404, "Not found"))

  def run do
    start()
    Process.sleep(:infinity)
  end

  def start(options \\ []) do
    Logger.configure(level: :info)
    config = Application.fetch_env!(:order_desk, :telnyx)
    validate!(config)
    Application.put_env(:order_desk, :phone_review_actor, Parlora.ID.new())
    Application.put_env(:order_desk, :browser_origin, "http://localhost:#{config.review_port}")
    Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())
    Application.put_env(:order_desk, :browser_offline, false)

    {:ok, _diagnostics} = Supervisor.start_child(OrderDesk.Supervisor, OrderDesk.PhoneDiagnostics)

    {:ok, _supervisor} =
      Supervisor.start_child(OrderDesk.Supervisor, {OrderDesk.TelnyxSupervisor, config})

    for {id, module, port} <- [
          {:telnyx_http, Keyword.get(options, :public_plug, __MODULE__), config.port},
          {:telnyx_review, Keyword.get(options, :private_plug, OrderDesk.BrowserServer),
           config.review_port}
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
      "Telnyx demo ready. Tunnel only port #{config.port}. Review: http://localhost:#{config.review_port}/phone-review"
    )

    IO.puts(
      "Use isolated demonstration data. Calls last at most 180 seconds. Caller ID does not authenticate a customer."
    )

    :ok
  end

  defp authorize(ticket, token) do
    with {:ok, channel_options} <- TelnyxGate.claim(ticket, token) do
      {:ok,
       [
         channel_options: channel_options,
         lifecycle_owner: Process.whereis(TelnyxGate),
         start_session: fn channel ->
           with {:ok, session} <-
                  OrderDesk.BrowserGate.start_session(
                    channel,
                    Application.fetch_env!(:order_desk, :phone_review_actor),
                    audio_format: Parlora.AudioFormat.pcmu()
                  ) do
             :ok = OrderDesk.PhoneDiagnostics.attach(session)
             {:ok, session}
           end
         end,
         on_ready: &OrderDesk.Greeting.start/1
       ]}
    end
  end

  defp admit(conn, _options) do
    case TelnyxGate.admit_request() do
      :ok -> conn
      _limited -> conn |> send_resp(429, "Too many requests") |> halt()
    end
  end

  defp validate!(config) do
    uri = URI.parse(config.public_url || "")

    unless uri.scheme == "https" and is_binary(uri.host) and uri.path in [nil, ""] and
             uri.port == 443 and uri.query == nil and uri.fragment == nil and uri.userinfo == nil,
           do: raise("TELNYX_PUBLIC_URL must be an HTTPS origin without a path or query")

    required = [
      config.api_key,
      config.phone_number,
      config.connection_id,
      config.public_key,
      OrderDesk.Provider.credential()
    ]

    unless Enum.all?(required, &(is_binary(&1) and byte_size(&1) > 0)),
      do: raise("Telnyx and voice-provider runtime credentials are required")

    unless match?({:ok, <<_key::binary-size(32)>>}, Base.decode64(config.public_key)),
      do: raise("Telnyx webhook public key must contain 32 Base64-encoded bytes")

    unless Process.whereis(OrderDesk.TypeSafe), do: raise("TYPESAFE_API_KEY is required")
  end
end
