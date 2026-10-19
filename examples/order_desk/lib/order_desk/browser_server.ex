defmodule OrderDesk.BrowserServer do
  @moduledoc "Host-owned browser listener, routes, origin checks, and session admission."
  use Plug.Router
  alias Parlora.Channels.Browser.Signaling

  plug(:cookie_secret)

  plug(:browser_session)

  plug(:fetch_session)
  plug(:browser_identity)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, length: 8_192)
  plug(:match)
  plug(:dispatch)

  def run do
    # Dependency debug logs include ICE credentials and private network details.
    Logger.configure(level: :info)
    port = System.get_env("PORT", "4000") |> String.to_integer()
    origin = System.get_env("BROWSER_ORIGIN", "http://localhost:#{port}")
    Application.put_env(:order_desk, :browser_origin, origin)
    Application.put_env(:order_desk, :browser_ice, OrderDesk.BrowserICE.load_env())

    if System.get_env("PARLORA_AUDIO_DIAGNOSTICS") == "1" do
      {:ok, _} =
        Supervisor.start_child(OrderDesk.Supervisor, OrderDesk.BrowserAudioDiagnostics)
    end

    Application.put_env(
      :order_desk,
      :browser_offline,
      System.get_env("PARLORA_BROWSER_OFFLINE") == "1"
    )

    unless Application.get_env(:order_desk, :browser_offline) or
             Process.whereis(OrderDesk.TypeSafe),
           do: raise("Set TYPESAFE_API_KEY or use scripts/browser.sh on macOS")

    {:ok, _} =
      Supervisor.start_child(
        OrderDesk.Supervisor,
        {Bandit, plug: __MODULE__, ip: {127, 0, 0, 1}, port: port}
      )

    IO.puts(
      "OrderDesk browser: #{origin}. Listener is loopback-only; one call lasts at most 180 seconds."
    )

    Process.sleep(:infinity)
  end

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(%{active_sessions: OrderDesk.BrowserGate.count()}))
  end

  get "/" do
    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; connect-src 'self'; media-src 'self' blob:; script-src 'self'; style-src 'self'; frame-ancestors 'none'"
    )
    |> put_resp_header("permissions-policy", "microphone=(self), camera=()")
    |> send_page()
  end

  get "/phone-review" do
    # This route exists only on the loopback browser listener. The public Twilio
    # listener does not mount it. All development phone calls share synthetic data.
    case phone_review_actor() do
      actor when is_binary(actor) ->
        conn
        |> put_session(:actor, actor)
        |> put_session(:csrf, Parlora.ID.new())
        |> put_resp_header("location", "/")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(303, "")

      _disabled ->
        send_resp(conn, 404, "Not found")
    end
  end

  get("/voice.js", do: send_asset(conn, "voice.js", "text/javascript"))
  get("/style.css", do: send_asset(conn, "style.css", "text/css"))
  get("/orders.js", do: send_asset(conn, "orders.js", "text/javascript"))

  get "/audio-diagnostics.js" do
    if Process.whereis(OrderDesk.BrowserAudioDiagnostics),
      do: send_asset(conn, "audio-diagnostics.js", "text/javascript"),
      else: send_resp(conn, 404, "Not found")
  end

  get "/api/audio-diagnostics" do
    conn = fetch_query_params(conn)

    if Process.whereis(OrderDesk.BrowserAudioDiagnostics),
      do:
        json(
          conn,
          200,
          OrderDesk.BrowserAudioDiagnostics.snapshot(
            get_session(conn, :actor),
            conn.query_params["summary"] != "1",
            conn.query_params["session_id"]
          )
        ),
      else: send_resp(conn, 404, "Not found")
  end

  get "/dev/recorded-input.js" do
    if Application.get_env(:order_desk, :recorded_input, false),
      do: send_asset(conn, "recorded-input.js", "text/javascript"),
      else: send_resp(conn, 404, "Not found")
  end

  get "/dev/audio/:clip" do
    name = "test-audio/#{clip}"

    if Application.get_env(:order_desk, :recorded_input, false) and
         clip in [
           "draft.wav",
           "refuse.wav",
           "items.wav",
           "package.wav",
           "correct.wav",
           "interrupt.wav"
         ] and
         File.regular?(Application.app_dir(:order_desk, "priv/browser/#{name}")),
       do: send_asset(conn, name, "audio/wav"),
       else: send_resp(conn, 404, "Not found")
  end

  get "/api/orders" do
    dashboard = OrderDesk.Store.dashboard(get_session(conn, :actor))

    json(
      conn,
      200,
      Map.merge(dashboard, %{
        csrf: get_session(conn, :csrf),
        interpretation: OrderDesk.Interpretation.stats()
      })
    )
  end

  post "/api/proposals" do
    if mutation_allowed?(conn) do
      result =
        OrderDesk.Store.propose(
          get_session(conn, :actor),
          conn.body_params["order"],
          conn.body_params["instructions"],
          conn.body_params["id"]
        )

      case result do
        {:ok, proposal} -> json(conn, 200, proposal)
        {:error, reason} -> json(conn, 422, %{error: reason})
      end
    else
      json(conn, 403, %{error: "Request rejected"})
    end
  end

  post "/api/proposals/:id/confirm" do
    if mutation_allowed?(conn) do
      params = %{actor: get_session(conn, :actor), proposal: id}

      case OrderDesk.Operations.confirm(params) do
        {:ok, %{outcome: "applied"} = result} ->
          unless result.result.duplicate,
            do: OrderDesk.BrowserGate.notify(get_session(conn, :actor), result.result)

          json(conn, 200, result)

        {:ok, result} ->
          json(conn, 409, result)

        _error ->
          json(conn, 503, %{
            error: "Confirmation outcome unavailable. Refresh before retrying the same proposal."
          })
      end
    else
      json(conn, 403, %{error: "Request rejected"})
    end
  end

  post "/api/proposals/:id/reject" do
    if mutation_allowed?(conn) do
      :ok = OrderDesk.Store.reject(get_session(conn, :actor), id)
      json(conn, 200, %{outcome: "rejected"})
    else
      json(conn, 403, %{error: "Request rejected"})
    end
  end

  post "/ice-config" do
    if allowed_origin?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, JSON.encode!(OrderDesk.BrowserICE.client_config()))
    else
      send_resp(conn, 403, "Origin rejected")
    end
  end

  get "/voice" do
    # This development application deliberately serves only the loopback host.
    # A deployed application must authenticate its user here before upgrading.
    if allowed_origin?(conn) do
      Signaling.upgrade(conn,
        start_session: fn channel ->
          OrderDesk.BrowserGate.start_session(channel, get_session(conn, :actor))
        end,
        on_ready: &__MODULE__.greet/1,
        channel_options: OrderDesk.BrowserICE.channel_options()
      )
    else
      send_resp(conn, 403, "Origin rejected")
    end
  end

  match(_, do: send_resp(conn, 404, "Not found"))

  def greet(session), do: OrderDesk.Greeting.start(session)

  defp send_asset(conn, name, type) do
    conn
    |> put_resp_content_type(type)
    |> put_resp_header("cache-control", "no-store")
    |> send_file(200, Application.app_dir(:order_desk, "priv/browser/#{name}"))
  end

  defp send_page(conn) do
    directory = Application.app_dir(:order_desk, "priv/browser")

    controls =
      if Application.get_env(:order_desk, :recorded_input, false),
        do: File.read!(Path.join(directory, "recorded-input.html")),
        else: ""

    page =
      directory
      |> Path.join("index.html")
      |> File.read!()
      |> String.replace("<!-- recorded-input -->", controls)
      |> String.replace(
        "<!-- audio-diagnostics -->",
        if(Process.whereis(OrderDesk.BrowserAudioDiagnostics),
          do: "<script src=\"/audio-diagnostics.js\" defer></script>",
          else: ""
        )
      )

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, page)
  end

  defp allowed_origin?(conn),
    do: get_req_header(conn, "origin") == [Application.fetch_env!(:order_desk, :browser_origin)]

  defp cookie_secret(conn, _opts),
    do: %{conn | secret_key_base: Application.fetch_env!(:order_desk, :cookie_secret)}

  defp browser_session(conn, _opts) do
    # Cookies are shared across localhost ports. Independent demo listeners have
    # different signing secrets and must not overwrite each other's sessions.
    origin = Application.get_env(:order_desk, :browser_origin)
    port = if is_binary(origin), do: URI.parse(origin).port, else: conn.port

    options =
      Plug.Session.init(
        store: :cookie,
        key: "order_desk_#{port}",
        signing_salt: "order-desk-browser",
        same_site: "Strict",
        http_only: true
      )

    Plug.Session.call(conn, options)
  end

  defp phone_review_actor,
    do:
      Application.get_env(:order_desk, :phone_review_actor) ||
        Application.get_env(:order_desk, :twilio_review_actor)

  defp browser_identity(conn, _opts) do
    actor = phone_review_actor()

    cond do
      is_binary(actor) and get_session(conn, :actor) != actor ->
        conn |> put_session(:actor, actor) |> put_session(:csrf, Parlora.ID.new())

      get_session(conn, :actor) ->
        conn

      true ->
        conn |> put_session(:actor, Parlora.ID.new()) |> put_session(:csrf, Parlora.ID.new())
    end
  end

  defp mutation_allowed?(conn),
    do:
      allowed_origin?(conn) and get_req_header(conn, "x-csrf-token") == [get_session(conn, :csrf)]

  defp json(conn, status, data),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, JSON.encode!(data))
end
