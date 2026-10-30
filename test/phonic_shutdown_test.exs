defmodule Parlora.PhonicShutdownTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, Event, Limits}
  alias Parlora.Providers.Phonic
  alias Parlora.Providers.Phonic.Protocol
  alias Parlora.TestSupport.TwilioPeer

  test "application close sends masked code 1000, accepts acknowledgment and is idempotent" do
    state = connection(:ack)
    {:reply, :ok, closed} = Phonic.handle_call({:close, "close", :session_closed}, nil, state)
    assert_receive {:peer_close, 1000}
    assert_receive :peer_eof
    assert closed.status == :closed and closed.socket == nil and closed.key == nil
    assert_receive {:parlora_event, %Event{type: :closed, payload: %{finalized?: false}}}
    refute_received {:parlora_event, %Event{type: :failed}}
    assert {:reply, :ok, ^closed} = Phonic.handle_call({:close, "again", :cancel}, nil, closed)
    refute_receive {:peer_close, _}, 10
  end

  test "normal process termination also sends a normal close" do
    state = connection(:ack)
    assert :ok = Phonic.terminate(:shutdown, state)
    assert_receive {:peer_close, 1000}
    assert_receive :peer_eof
  end

  test "unresponsive close peer is bounded by the configured shutdown budget" do
    state = connection(:silent)

    state = %{
      state
      | init: %{state.init | limits: %{state.init.limits | shutdown_timeout_ms: 40}}
    }

    started = System.monotonic_time(:millisecond)
    {:reply, :ok, closed} = Phonic.handle_call({:close, "close", :cancel}, nil, state)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 25 and elapsed < 500
    assert closed.status == :closed
    assert_receive {:peer_close, 1000}
    assert_receive :peer_eof
    refute_received {:parlora_event, %Event{type: :failed}}
  end

  test "tail frames are discarded and unrelated messages survive the close handshake" do
    state = connection(:tail)
    send(self(), :unrelated_application_message)
    {:reply, :ok, _closed} = Phonic.handle_call({:close, "close", :cancel}, nil, state)
    assert_receive {:peer_close, 1000}
    assert_receive :unrelated_application_message
    refute_received {:parlora_event, %Event{type: :failed}}
    refute_received {:parlora_event, %Event{type: :transcript_delta}}
  end

  test "a silent peer cannot consume the default five-second session shutdown budget" do
    state = connection(:silent)
    started = System.monotonic_time(:millisecond)
    {:reply, :ok, _closed} = Phonic.handle_call({:close, "close", :cancel}, nil, state)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 200 and elapsed < 1_000
    assert_receive {:peer_close, 1000}
    assert_receive :peer_eof
  end

  test "failure shutdown remains abrupt and retains its failure classification" do
    state = connection(:ack)
    {:noreply, closed} = Phonic.handle_info(:phonic_startup_timeout, %{state | status: :starting})
    assert closed.status == :closed
    assert_receive :peer_eof
    refute_received {:peer_close, _}

    assert_receive {:parlora_event,
                    %Event{
                      type: :failed,
                      payload: %{error: %{details: %{reason: :startup_timeout}}}
                    }}
  end

  test "closing before WebSocket initialization falls back to transport cleanup" do
    state = connection(:ack)
    state = %{state | socket: %{state.socket | ws: nil}, status: :starting}
    {:reply, :ok, closed} = Phonic.handle_call({:close, "close", :cancel}, nil, state)
    assert closed.status == :closed
    assert_receive :peer_eof
    refute_received {:peer_close, _}
  end

  test "TLS teardown does not wait five seconds after the WebSocket close acknowledgment" do
    state = connection(:tls_hold, :ssl)
    started = System.monotonic_time(:millisecond)
    {:reply, :ok, _closed} = Phonic.handle_call({:close, "close", :cancel}, nil, state)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:peer_close, 1000}
    send(state.test_peer, :release)
    assert_receive :peer_eof
  end

  defp connection(mode, transport \\ :gen_tcp) do
    options = [:binary, active: false, ip: {127, 0, 0, 1}]

    options =
      if transport == :ssl,
        do:
          options ++
            :public_key.pkix_test_data(%{
              root: [digest: :sha256, key: {:rsa, 2048, 65_537}],
              peer: [digest: :sha256, key: {:rsa, 2048, 65_537}]
            }),
        else: options

    {:ok, listener} = transport.listen(0, options)
    {:ok, {_ip, port}} = sockname(transport, listener)
    owner = self()
    server = spawn_link(fn -> serve(listener, owner, mode, transport) end)

    on_exit(fn ->
      transport.close(listener)
      Process.exit(server, :kill)
    end)

    {:ok, peer} = connect(transport, port)
    {:ok, conn} = Mint.HTTP.set_mode(peer.conn, :active)

    init = %AdapterInit{
      session_id: "shutdown",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, config} = Protocol.start([api_key: "test"], init.audio_format)
    {:ok, state, _} = Phonic.init({init, [api_key: "test"], config})

    state = Map.put(state, :test_peer, server)

    %{
      state
      | socket: %{conn: conn, ref: peer.ref, ws: peer.websocket, status: 101, headers: []},
        status: :ready
    }
  end

  defp serve(listener, owner, mode, transport) do
    {:ok, socket} = accept(transport, listener)
    headers = headers(socket, "", transport)
    [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, headers)
    accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      transport.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

    case transport.recv(socket, 2, 2_000) do
      {:ok, <<0x88, 1::1, 2::7>>} ->
        {:ok, <<mask::binary-size(4), payload::binary-size(2)>>} =
          transport.recv(socket, 6, 2_000)

        <<code::16>> =
          for {byte, index} <- Enum.with_index(:binary.bin_to_list(payload)),
              into: <<>>,
              do: <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>

        send(owner, {:peer_close, code})
        if mode == :tail, do: transport.send(socket, <<0x81, 1, ?{>>)
        if mode != :silent, do: transport.send(socket, <<0x88, 2, 1000::16>>)

        if mode == :tls_hold do
          receive do
            :release -> :ok
          after
            1_500 -> :ok
          end
        end

        {:error, :closed} = transport.recv(socket, 0, 2_000)
        send(owner, :peer_eof)

      {:error, :closed} ->
        send(owner, :peer_eof)
    end

    transport.close(socket)
  end

  defp headers(socket, bytes, transport) do
    if String.ends_with?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, more} = transport.recv(socket, 0, 2_000)
      headers(socket, bytes <> more, transport)
    end
  end

  defp sockname(:gen_tcp, listener), do: :inet.sockname(listener)
  defp sockname(:ssl, listener), do: :ssl.sockname(listener)
  defp accept(:gen_tcp, listener), do: :gen_tcp.accept(listener)

  defp accept(:ssl, listener) do
    {:ok, socket} = :ssl.transport_accept(listener)
    :ssl.handshake(socket)
  end

  defp connect(:gen_tcp, port), do: TwilioPeer.connect_headers(port, "/", [])

  defp connect(:ssl, port) do
    {:ok, conn} =
      Mint.HTTP.connect(:https, "localhost", port,
        mode: :passive,
        protocols: [:http1],
        transport_opts: [verify: :verify_none]
      )

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:wss, conn, "/", [])
    handshake(conn, ref, [])
  end

  defp handshake(conn, ref, responses) do
    {:ok, conn, more} = Mint.HTTP.recv(conn, 0, 2_000)
    responses = responses ++ more

    if {:done, ref} in responses do
      {:status, ^ref, 101} = Enum.find(responses, &match?({:status, _, _}, &1))
      {:headers, ^ref, headers} = Enum.find(responses, &match?({:headers, _, _}, &1))
      {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, 101, headers, mode: :passive)
      {:ok, %{conn: conn, ref: ref, websocket: ws}}
    else
      handshake(conn, ref, responses)
    end
  end
end
