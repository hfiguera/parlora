defmodule Parlora.Channels.Telnyx.Signature do
  @moduledoc """
  Ed25519 verification of Telnyx v2 webhooks using the original body bytes.

  Pass the Base64 public key from the host's configuration. The default freshness
  window is 300 seconds in either direction. Fresh signatures may still be
  duplicates: the application must atomically deduplicate verified event IDs and
  retain terminal call identities before acknowledging webhook admission.
  """

  @spec valid?(binary(), binary(), binary(), binary(), keyword()) :: boolean()
  def valid?(public_key, timestamp, body, signature, options \\ [])

  def valid?(public_key, timestamp, body, signature, options)
      when is_binary(public_key) and byte_size(public_key) == 44 and is_binary(timestamp) and
             byte_size(timestamp) in 1..16 and is_binary(body) and is_binary(signature) and
             byte_size(signature) == 88 do
    now = Keyword.get(options, :now, System.system_time(:second))
    tolerance = Keyword.get(options, :tolerance_seconds, 300)

    with true <- valid_window?(now, tolerance),
         {seconds, ""} when seconds >= 0 <- Integer.parse(timestamp),
         true <- Integer.to_string(seconds) == timestamp and abs(now - seconds) <= tolerance,
         {:ok, key} when byte_size(key) == 32 <- Base.decode64(public_key),
         {:ok, signed} when byte_size(signed) == 64 <- Base.decode64(signature) do
      :crypto.verify(:eddsa, :none, timestamp <> "|" <> body, signed, [key, :ed25519])
    else
      _invalid -> false
    end
  rescue
    ArgumentError -> false
    ErlangError -> false
  end

  def valid?(_public_key, _timestamp, _body, _signature, _options), do: false

  defp valid_window?(now, tolerance),
    do: is_integer(now) and is_integer(tolerance) and tolerance in 1..300

  @doc "Reject absent or repeated signature headers before verifying the raw body."
  def verify(conn, public_key, body, options \\ []) do
    with [timestamp] <- Plug.Conn.get_req_header(conn, "telnyx-timestamp"),
         [signature] <- Plug.Conn.get_req_header(conn, "telnyx-signature-ed25519"),
         true <- valid?(public_key, timestamp, body, signature, options) do
      :ok
    else
      _invalid -> {:error, :invalid_signature}
    end
  end
end
