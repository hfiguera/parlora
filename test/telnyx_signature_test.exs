defmodule Parlora.TelnyxSignatureTest do
  use ExUnit.Case, async: true
  alias Parlora.Channels.Telnyx.Signature

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: Base.encode64(public), private: private}
  end

  test "authenticates exact body bytes and timestamp, not parsed/re-encoded JSON", context do
    body = ~s({ "data": {"id":"event-1"} })
    signature = sign(context.private, "1000", body)
    assert Signature.valid?(context.public, "1000", body, signature, now: 1000)
    refute Signature.valid?(context.public, "1001", body, signature, now: 1000)
    refute Signature.valid?(context.public, "1000", body <> "\n", signature, now: 1000)

    refute Signature.valid?(
             context.public,
             "1000",
             JSON.encode!(JSON.decode!(body)),
             signature,
             now: 1000
           )
  end

  test "rejects old, future, noncanonical and malformed signatures", context do
    body = "{}"

    for timestamp <- ["699", "1301", "+1000", "01000", "1000x", "-1"] do
      refute Signature.valid?(
               context.public,
               timestamp,
               body,
               sign(context.private, timestamp, body),
               now: 1000
             )
    end

    signature = sign(context.private, "1000", body)
    refute Signature.valid?(context.public, "1000", body, signature, tolerance_seconds: :infinity)
    refute Signature.valid?(context.public, "1000", body, String.duplicate("!", 88), now: 1000)
    refute Signature.valid?(Base.encode64(<<0::256>>), "1000", body, signature, now: 1000)
    refute Signature.valid?(nil, "1000", body, signature)
    refute Signature.valid?(context.public, "1000", body, nil)
  end

  test "requires exactly one of each header", context do
    timestamp = Integer.to_string(System.system_time(:second))
    signature = sign(context.private, timestamp, "{}")

    conn =
      Plug.Test.conn(:post, "/telnyx/events", "{}")
      |> Plug.Conn.put_req_header("telnyx-timestamp", timestamp)
      |> Plug.Conn.put_req_header("telnyx-signature-ed25519", signature)

    assert :ok = Signature.verify(conn, context.public, "{}")
    repeated = %{conn | req_headers: [{"telnyx-timestamp", timestamp} | conn.req_headers]}
    assert {:error, :invalid_signature} = Signature.verify(repeated, context.public, "{}")
    assert {:error, :invalid_signature} = Signature.verify(conn, context.public, "{ }")
  end

  defp sign(private, timestamp, body),
    do:
      :crypto.sign(:eddsa, :none, timestamp <> "|" <> body, [private, :ed25519])
      |> Base.encode64()
end
