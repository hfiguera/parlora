defmodule Parlora.TelnyxEndpointTest do
  use ExUnit.Case, async: true
  alias Parlora.Channels.Telnyx.Endpoint

  test "only authentic raw JSON reaches bounded application admission" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    data = %{
      "id" => "event-1",
      "event_type" => "call.initiated",
      "occurred_at" => "2026-09-18T12:00:00Z",
      "payload" => %{}
    }

    body = Jason.encode!(%{"data" => data})

    options = [
      public_key: Base.encode64(public),
      on_event: fn event ->
        send(self(), {:verified, event})
        :ok
      end
    ]

    assert Endpoint.webhook(signed(body, private), options).status == 200
    assert_receive {:verified, ^data}

    for conn <- [
          Plug.Test.conn(:post, "/events", body),
          signed(body <> " ", private)
          |> Plug.Conn.put_req_header("telnyx-signature-ed25519", "invalid"),
          signed(String.duplicate("x", 16_385), private)
        ] do
      assert Endpoint.webhook(conn, options).status == 403
      refute_receive {:verified, _data}, 5
    end

    saturated = Keyword.put(options, :on_event, fn _event -> {:error, :backpressure} end)
    assert Endpoint.webhook(signed(body, private), saturated).status == 503
  end

  test "media upgrade requires a separate authentication header before invoking authorization" do
    options = [authorize: fn _conn, _token -> flunk("unauthenticated upgrade") end]
    assert Endpoint.upgrade(Plug.Test.conn(:get, "/media"), options).status == 403
  end

  defp signed(body, private) do
    timestamp = to_string(System.system_time(:second))

    signature =
      :crypto.sign(:eddsa, :none, timestamp <> "|" <> body, [private, :ed25519])
      |> Base.encode64()

    Plug.Test.conn(:post, "/events", body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("telnyx-timestamp", timestamp)
    |> Plug.Conn.put_req_header("telnyx-signature-ed25519", signature)
  end
end
