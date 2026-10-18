defmodule Parlora.Channels.Twilio.Signature do
  @moduledoc """
  Twilio HMAC-SHA1 request verification using an explicit public URL.

  The host supplies the exact externally visible signing URL. No request Host,
  Origin or forwarded header is trusted to construct it. Pass all decoded form
  parameters for a POST callback and an empty map for the WebSocket GET upgrade.
  """

  @spec valid?(binary(), binary(), map(), binary()) :: boolean()
  def valid?(token, url, params, signature)
      when is_binary(token) and byte_size(token) > 0 and is_binary(url) and is_map(params) and
             is_binary(signature) and byte_size(signature) == 28 do
    if Enum.all?(params, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      fields = params |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)
      expected = :crypto.mac(:hmac, :sha, token, [url, fields]) |> Base.encode64()
      Plug.Crypto.secure_compare(expected, signature)
    else
      false
    end
  end

  def valid?(_token, _url, _params, _signature), do: false

  @doc "Validate against an explicit URL, requiring the local request path/query to match."
  def verify(conn, token, url, params) do
    uri = URI.parse(url)

    with true <- uri.scheme in ["https", "wss"] and is_binary(uri.host) and uri.userinfo == nil,
         true <- uri.scheme != "wss" or conn.method == "GET",
         true <- conn.request_path == uri.path and conn.query_string == (uri.query || ""),
         [signature] <- Plug.Conn.get_req_header(conn, "x-twilio-signature"),
         true <- valid?(token, url, params, signature) do
      :ok
    else
      _invalid -> {:error, :invalid_signature}
    end
  end
end
