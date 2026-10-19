defmodule OrderDesk.BrowserICETest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn
  alias OrderDesk.{BrowserICE, BrowserServer}

  setup do
    filename = Path.join(System.tmp_dir!(), "parlora-turn-#{System.unique_integer([:positive])}")
    secret = :crypto.strong_rand_bytes(32) |> Base.encode16()
    File.write!(filename, secret)
    File.chmod!(filename, 0o600)

    on_exit(fn ->
      File.rm(filename)
      Application.delete_env(:order_desk, :browser_ice)
      Application.delete_env(:order_desk, :browser_origin)
    end)

    %{filename: filename, secret: secret}
  end

  test "default direct mode and invalid or incomplete relay configuration" do
    assert %{iceServers: [], iceTransportPolicy: "all"} =
             BrowserICE.load_env(fn _key -> nil end) |> BrowserICE.client_config()

    for env <- [
          %{"PARLORA_ICE_POLICY" => "invalid"},
          %{"PARLORA_ICE_POLICY" => "relay"},
          %{"PARLORA_TURN_URL" => "https://wrong.invalid"},
          %{"PARLORA_TURN_URL" => "turn:example.invalid"}
        ] do
      assert_raise ArgumentError, fn -> BrowserICE.load_env(&Map.get(env, &1)) end
    end
  end

  test "fresh expiring credentials agree with coturn HMAC and never expose the shared secret",
       ctx do
    env = %{
      "PARLORA_STUN_URL" => "stun:example.invalid:3478",
      "PARLORA_TURN_URL" => "turn:example.invalid:3478?transport=udp",
      "PARLORA_TURN_SECRET_FILE" => ctx.filename,
      "PARLORA_ICE_POLICY" => "relay"
    }

    config = BrowserICE.load_env(&Map.get(env, &1))
    first = BrowserICE.client_config(config)
    second = BrowserICE.client_config(config)
    [_, turn] = first.iceServers
    [expiry, _nonce] = String.split(turn.username, ":")

    assert String.to_integer(expiry) in (System.os_time(:second) + 598)..(System.os_time(:second) +
                                                                            600)

    assert turn.credential == Base.encode64(:crypto.mac(:hmac, :sha, ctx.secret, turn.username))
    assert first != second
    refute JSON.encode!(first) =~ ctx.secret

    Application.put_env(:order_desk, :browser_ice, config)
    Application.put_env(:order_desk, :browser_origin, "http://localhost:4000")
    assert BrowserICE.channel_options()[:ice_transport_policy] == :relay

    for origin <- [nil, "http://untrusted.invalid"] do
      conn = conn(:post, "/ice-config")
      conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
      assert BrowserServer.call(conn, BrowserServer.init([])).status == 403
    end

    response =
      conn(:post, "/ice-config")
      |> put_req_header("origin", "http://localhost:4000")
      |> BrowserServer.call(BrowserServer.init([]))

    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert JSON.decode!(response.resp_body)["iceTransportPolicy"] == "relay"
    refute response.resp_body =~ ctx.secret
    assert OrderDesk.BrowserGate.count() == 0
  end
end
