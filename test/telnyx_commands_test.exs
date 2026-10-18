defmodule Parlora.TelnyxCommandsTest do
  use ExUnit.Case, async: true
  alias Parlora.Channels.Telnyx.Commands

  defmodule Server do
    import Plug.Conn
    def init(options), do: options

    def call(conn, options) do
      {:ok, body, conn} = read_body(conn)

      send(
        options[:owner],
        {:request, conn.request_path, get_req_header(conn, "authorization"), body}
      )

      response = Agent.get_and_update(options[:responses], fn [head | tail] -> {head, tail} end)

      case response do
        {:limited, reset} ->
          conn |> put_resp_header("x-ratelimit-reset", reset) |> send_resp(429, "rate limited")

        {:delay, duration} ->
          Process.sleep(duration)
          send_resp(conn, 200, ~s({"data":{"result":"ok"}}))

        {status, body} ->
          send_resp(conn, status, body)
      end
    end
  end

  test "retries transient failures with exactly the same command identity and body" do
    options = server([{503, "temporarily unavailable"}, {200, ~s({"data":{"result":"ok"}})}])

    assert {:ok, %{attempts: 2, command_id: "stable-id", accepted?: true}} =
             Commands.execute(:answer, "v3:call/opaque", "stable-id", %{}, options)

    for _attempt <- 1..2 do
      assert_receive {:request, "/v2/calls/v3%3Acall%2Fopaque/actions/answer",
                      ["Bearer test-key"], body}

      assert Jason.decode!(body) == %{"command_id" => "stable-id"}
    end
  end

  test "permanent rejection and redirects are not retried or leaked" do
    for status <- [401, 403, 422, 302] do
      options = server([{status, "private upstream response"}])

      assert {:error, error} = Commands.execute(:hangup, "call", "id", %{}, options)
      assert error.details.http_status == status
      assert error.details.attempts == 1
      refute inspect(error) =~ "private upstream response"
      refute inspect(error) =~ "test-key"
    end
  end

  test "a rate-limit reset beyond the command deadline is not retried early" do
    options = server([{:limited, "60"}]) |> Keyword.put(:timeout_ms, 1_000)

    assert {:error, %{details: %{http_status: 429, attempts: 1}}} =
             Commands.execute(:answer, "call", "rate-id", %{}, options)
  end

  test "already-ended responses preserve call-state evidence without claiming command acceptance" do
    body = Jason.encode!(%{errors: [%{code: "90018", detail: "private upstream text"}]})

    for responses <- [[{422, body}], [{503, "unavailable"}, {422, body}]] do
      options = server(responses)
      assert {:error, error} = Commands.execute(:hangup, "call", "id", %{}, options)
      assert error.details.http_status == 422
      assert error.details.telnyx_codes == ["90018"]
      assert error.details.remote_call_state == :ended
      assert error.details.outcome == :unknown
      assert error.details.attempts == length(responses)
      refute inspect(error) =~ "private upstream text"
    end
  end

  test "unrelated, malformed and mixed errors cannot establish that a call ended" do
    for {status, body} <- [
          {422, ~s({"errors":[{"code":"90015"}]})},
          {422, ~s({"errors":[{"code":"90018"},{"code":"90015"}]})},
          {422, ~s({"errors":[{"code":"90018"},{}]})},
          {422, ~s({"errors":[{"code":"private-key"}]})},
          {422, ~s({"errors":[]})},
          {422, "invalid JSON"},
          {403, ~s({"errors":[{"code":"90018"}]})}
        ] do
      assert {:error, error} =
               Commands.execute(:hangup, "call", "id", %{}, server([{status, body}]))

      refute Map.has_key?(error.details, :remote_call_state)
      refute inspect(error) =~ "private-key"
    end

    errors = for code <- 10_000..10_020, do: %{code: to_string(code)}
    options = server([{422, Jason.encode!(%{errors: errors})}])
    assert {:error, error} = Commands.execute(:hangup, "call", "id", %{}, options)
    assert Enum.count_until(error.details.telnyx_codes, 9) == 8
  end

  test "bounds attempts, response bytes and total receive time" do
    options = server(List.duplicate({503, "unavailable"}, 3))

    assert {:error, %{details: %{attempts: 3}}} =
             Commands.execute(:answer, "call", "id", %{}, options)

    options = server([{200, String.duplicate("x", 16_385)}])

    assert {:error, %{details: %{reason: :response_too_large, attempts: 1}}} =
             Commands.execute(:answer, "call", "id", %{}, options)

    options = server([{:delay, 500}]) |> Keyword.put(:timeout_ms, 50)
    start = System.monotonic_time(:millisecond)

    assert {:error, %{details: %{outcome: :unknown}}} =
             Commands.execute(:answer, "call", "id", %{}, options)

    assert System.monotonic_time(:millisecond) - start < 400
  end

  test "streaming uses explicit raw PCMU and sends playback to the answered caller leg" do
    options = server([{200, ~s({"data":{"result":"ok"}})}])
    params = Commands.stream_options("wss://example.test/media", "call-specific-token")

    assert {:ok, _accepted} =
             Commands.execute(:streaming_start, "call", "start-id", params, options)

    assert_receive {:request, "/v2/calls/call/actions/streaming_start", _headers, body}
    fields = Jason.decode!(body)
    assert fields["stream_auth_token"] == "call-specific-token"
    assert fields["stream_bidirectional_mode"] == "rtp"
    assert fields["stream_codec"] == "PCMU"
    assert fields["stream_bidirectional_codec"] == "PCMU"
    assert fields["stream_bidirectional_sampling_rate"] == 8_000
    assert fields["stream_bidirectional_target_legs"] == "self"
  end

  test "rejects unsupported actions and insecure non-loopback configuration before network I/O" do
    options = [api_key: "secret", base_url: "http://example.test/v2"]

    assert {:error, %{code: :invalid_argument}} =
             Commands.execute(:answer, "call", "id", %{}, options)

    assert {:error, %{code: :invalid_argument}} =
             Commands.execute(:dial, "call", "id", %{}, options)

    assert {:error, %{code: :invalid_argument}} = Commands.execute(:answer, "call", "id", %{}, [])
  end

  defp server(responses) do
    agent = start_supervised!({Agent, fn -> responses end}, id: make_ref())

    server =
      start_supervised!(
        {Bandit, plug: {Server, owner: self(), responses: agent}, ip: {127, 0, 0, 1}, port: 0},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    [api_key: "test-key", base_url: "http://127.0.0.1:#{port}/v2"]
  end
end
