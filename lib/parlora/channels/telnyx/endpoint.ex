defmodule Parlora.Channels.Telnyx.Endpoint do
  @moduledoc """
  Mountable signed Telnyx v2 webhook admission. This module starts no listener.

  Mount `webhook/2` before a JSON body parser. Supply `:public_key` and a bounded
  `:on_event` admission callback. The callback must atomically authorize and
  deduplicate the verified event and enqueue admitted work. It returns one of
  these values; return `:ok` for an already admitted duplicate too:

  | Callback return | HTTP status | Response body |
  | --- | --- | --- |
  | `:ok` | 200 | `"OK"` |
  | `{:error, :backpressure}` | 503 | `"Unavailable"` |
  | `{:error, reason}` for any other reason | 403 | `"Forbidden"` |

  The 503 response allows Telnyx to retry delivery. Do not perform REST commands
  in the admission callback; run them in supervised workers.

  Signature freshness does not replace event/call deduplication. The host retains
  terminal call identities and enforces listener, mailbox and concurrency bounds.
  Neither caller ID nor possession of an event ID authenticates an application user.
  """
  alias Parlora.Channels.MediaStream.Socket
  alias Parlora.Channels.Telnyx.Signature
  alias Plug.Conn

  @doc "Verify the exact bounded request body before decoding or invoking application code."
  def webhook(%Conn{method: "POST"} = conn, options) do
    with [content_type] <- Conn.get_req_header(conn, "content-type"),
         true <- content_type |> String.split(";") |> hd() == "application/json",
         {:ok, body, conn} <-
           Conn.read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 1_000),
         :ok <- Signature.verify(conn, Keyword.fetch!(options, :public_key), body),
         {:ok, %{"data" => data}} <- JSON.decode(body),
         true <- valid_event?(data) do
      case Keyword.fetch!(options, :on_event).(data) do
        :ok -> respond(conn, 200, "OK")
        {:error, :backpressure} -> respond(conn, 503, "Unavailable")
        {:error, _reason} -> respond(conn, 403, "Forbidden")
      end
    else
      _invalid -> respond(conn, 403, "Forbidden")
    end
  end

  def webhook(conn, _options), do: respond(conn, 403, "Forbidden")

  @doc """
  Admit a media upgrade using Telnyx's separate authentication header.

  The host's `:authorize` callback receives `(conn, token)` and must atomically
  compare/consume an expiring, call-bound token before returning
  `{:ok, socket_options}`. Use constant-time comparison. The API key is never a
  stream credential. Never accept an unverified token echoed in a connected frame.
  """
  def upgrade(%Conn{method: "GET"} = conn, options) do
    with [token] <- Conn.get_req_header(conn, "x-telnyx-streaming-auth-token"),
         true <- byte_size(token) in 32..4_000,
         {:ok, socket_options} <- Keyword.fetch!(options, :authorize).(conn, token) do
      Socket.upgrade(
        conn,
        socket_options,
        Parlora.Channels.Telnyx,
        :parlora_telnyx
      )
    else
      _invalid -> respond(conn, 403, "Forbidden")
    end
  end

  def upgrade(conn, _options), do: respond(conn, 403, "Forbidden")

  defp valid_event?(%{
         "id" => id,
         "event_type" => type,
         "occurred_at" => time,
         "payload" => payload
       })
       when is_binary(id) and byte_size(id) in 1..128 and is_binary(type) and
              byte_size(type) in 1..128 and is_binary(time) and byte_size(time) in 1..64 and
              is_map(payload) do
    match?({:ok, _time, _offset}, DateTime.from_iso8601(time))
  end

  defp valid_event?(_event), do: false

  defp respond(conn, status, text), do: conn |> Conn.send_resp(status, text) |> Conn.halt()
end
