defmodule Parlora.Channels.Twilio.Endpoint do
  @moduledoc """
  Mountable, signed incoming-call and WebSocket routes. No listener is started.

  `voice/2` verifies a bounded form POST against `:public_url` and `:auth_token`,
  and checks `:account_sid`. Only then is `:on_call` invoked with the signed
  parameters. That host callback authorizes/admit the call and returns
  `{:ok, wss_url}` or `{:error, reason}`. Use an expiring, single-use path ticket
  to associate that stream URL with the authenticated call and application actor.

  `upgrade/2` verifies a GET against its explicit WSS `:public_url`, then calls
  the host's `:authorize` function with the connection. It must atomically admit
  the socket and return `{:ok, socket_options}` with the authorized call identity.
  The listener must also enforce connection/rate limits and finite timeouts.
  Arbitrary forwarded headers never determine the signing URL.

  The generated TwiML explicitly places Hangup after Connect; this example policy
  ends a call after the stream closes. The channel itself makes no hangup claim.
  """
  alias Parlora.Channels.Twilio.{Protocol, Signature, Socket}
  alias Plug.Conn

  def voice(%Conn{method: "POST"} = conn, options) do
    with [content_type] <- Conn.get_req_header(conn, "content-type"),
         true <- content_type |> String.split(";") |> hd() == "application/x-www-form-urlencoded",
         {:ok, body, conn} <-
           Conn.read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 1_000),
         {:ok, params} <- form(body),
         :ok <- verify(conn, options, params),
         true <- params["AccountSid"] == Keyword.fetch!(options, :account_sid),
         true <- Protocol.sid?(params["CallSid"], "CA"),
         {:ok, stream_url} <- Keyword.fetch!(options, :on_call).(params),
         {:ok, xml} <- twiml(stream_url) do
      conn |> Conn.put_resp_content_type("text/xml") |> Conn.send_resp(200, xml) |> Conn.halt()
    else
      _invalid -> reject(conn)
    end
  end

  def voice(conn, _options), do: reject(conn)

  def upgrade(%Conn{method: "GET"} = conn, options) do
    with %{scheme: "wss"} <- URI.parse(Keyword.fetch!(options, :public_url)),
         :ok <- verify(conn, options, %{}),
         {:ok, socket_options} <- Keyword.fetch!(options, :authorize).(conn) do
      Socket.upgrade(conn, socket_options)
    else
      _invalid -> reject(conn)
    end
  end

  def upgrade(conn, _options), do: reject(conn)

  def twiml(url) when is_binary(url) and byte_size(url) <= 2_048 do
    uri = URI.parse(url)

    if uri.scheme == "wss" and is_binary(uri.host) and uri.userinfo == nil and
         uri.query == nil and uri.fragment == nil and String.valid?(url) do
      {:ok,
       "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Connect><Stream url=\"#{escape(url)}\" /></Connect><Hangup /></Response>"}
    else
      {:error, :invalid_stream_url}
    end
  end

  def twiml(_url), do: {:error, :invalid_stream_url}

  defp verify(conn, options, params),
    do:
      Signature.verify(
        conn,
        Keyword.fetch!(options, :auth_token),
        Keyword.fetch!(options, :public_url),
        params
      )

  defp form(body) do
    pairs = Enum.to_list(URI.query_decoder(body))
    params = Map.new(pairs)

    if Enum.count_until(pairs, 257) <= 256 and map_size(params) == Enum.count(pairs),
      do: {:ok, params},
      else: {:error, :invalid_form}
  rescue
    ArgumentError -> {:error, :invalid_form}
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("'", "&apos;")
  end

  defp reject(conn), do: conn |> Conn.send_resp(403, "Forbidden") |> Conn.halt()
end
