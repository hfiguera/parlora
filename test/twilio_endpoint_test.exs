defmodule Parlora.TwilioEndpointTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias Parlora.Channels.Twilio.{Endpoint, Signature}

  @url "https://example.com/myapp.php?foo=1&bar=2"
  @params %{
    "CallSid" => "CA1234567890ABCDE",
    "Caller" => "+14158675310",
    "Digits" => "1234",
    "From" => "+14158675310",
    "To" => "+18005551212"
  }
  @signature "L/OH5YylLD5NRKLltdqwSvS0BnU="

  test "official Twilio signature vector covers the exact URL and every decoded form value" do
    assert Signature.valid?("12345", @url, @params, @signature)
    refute Signature.valid?("different", @url, @params, @signature)
    refute Signature.valid?("12345", @url <> "/", @params, @signature)
    refute Signature.valid?("12345", @url, Map.delete(@params, "Digits"), @signature)
    refute Signature.valid?("12345", @url, @params, "invalid")

    conn =
      Plug.Test.conn(:post, "/myapp.php?foo=1&bar=2")
      |> put_req_header("x-twilio-signature", @signature)
      |> put_req_header("x-forwarded-host", "attacker.invalid")
      |> put_req_header("x-forwarded-proto", "http")

    assert :ok = Signature.verify(conn, "12345", @url, @params)

    assert {:error, :invalid_signature} =
             Signature.verify(%{conn | request_path: "/other"}, "12345", @url, @params)

    assert {:error, :invalid_signature} =
             Signature.verify(%{conn | query_string: ""}, "12345", @url, @params)
  end

  test "unsigned requests never reach the application call or socket admission callbacks" do
    options = [
      public_url: "https://example.com/voice",
      auth_token: "token",
      account_sid: "AC" <> String.duplicate("1", 32),
      on_call: fn _params -> flunk("unauthenticated voice admission") end,
      authorize: fn _conn -> flunk("unauthenticated socket admission") end
    ]

    conn =
      Plug.Test.conn(:post, "/voice", "CallSid=CA" <> String.duplicate("2", 32))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    assert Endpoint.voice(conn, options).status == 403
    assert Endpoint.upgrade(Plug.Test.conn(:get, "/voice"), options).status == 403
  end

  test "WebSocket signatures use the exact WSS URL, independently of proxy scheme" do
    url = "wss://example.com/media/ticket"
    signature = :crypto.mac(:hmac, :sha, "token", url) |> Base.encode64()

    conn =
      Plug.Test.conn(:get, "/media/ticket")
      |> put_req_header("x-twilio-signature", signature)
      |> put_req_header("x-forwarded-proto", "https")

    assert :ok = Signature.verify(conn, "token", url, %{})

    assert {:error, :invalid_signature} =
             Signature.verify(conn, "token", "https://example.com/media/ticket", %{})

    assert {:error, :invalid_signature} = Signature.verify(conn, "token", url <> "/", %{})

    assert {:error, :invalid_signature} =
             Signature.verify(%{conn | method: "POST"}, "token", url, %{})
  end

  test "signed call identity reaches host authorization and TwiML uses Connect with explicit Hangup" do
    account = "AC" <> String.duplicate("1", 32)
    call = "CA" <> String.duplicate("2", 32)

    params = %{
      "AccountSid" => account,
      "CallSid" => call,
      "UnknownFutureField" => " keep whitespace "
    }

    url = "https://example.com/voice"

    signature =
      :crypto.mac(:hmac, :sha, "token", [
        url,
        Enum.sort(params) |> Enum.map(fn {k, v} -> [k, v] end)
      ])
      |> Base.encode64()

    conn =
      Plug.Test.conn(:post, "/voice", URI.encode_query(params))
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> put_req_header("x-twilio-signature", signature)

    options = [
      public_url: url,
      auth_token: "token",
      account_sid: account,
      on_call: fn received ->
        assert received == params
        {:ok, "wss://example.com/stream/opaque-ticket"}
      end
    ]

    response = Endpoint.voice(conn, options)
    assert response.status == 200
    assert response.resp_body =~ "<Connect><Stream"
    assert response.resp_body =~ "</Connect><Hangup />"
    assert {:error, _error} = Endpoint.twiml("wss://example.com/stream?token=unsupported")
    assert {:error, _error} = Endpoint.twiml("ws://example.com/stream")
  end

  test "oversized and ambiguous form bodies are rejected before admission" do
    for body <- [String.duplicate("x", 16_385), "CallSid=one&CallSid=two"] do
      conn =
        Plug.Test.conn(:post, "/voice", body)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")

      assert Endpoint.voice(conn, []).status == 403
    end
  end
end
