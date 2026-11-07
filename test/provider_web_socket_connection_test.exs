defmodule Parlora.ProviderWebSocketConnectionTest do
  use ExUnit.Case, async: true

  alias Parlora.Provider.WebSocketConnection

  test "keeps the first server frame coalesced with the HTTP upgrade" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    greeting = ~s({"type":"session.created"})
    owner = self()

    server =
      Task.async(fn ->
        {:ok, client} = :gen_tcp.accept(listener, 2_000)
        request = read_headers(client, "")
        [_, key] = Regex.run(~r/^sec-websocket-key: ([^\r]+)\r$/im, request)

        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :ok =
          :gen_tcp.send(client, [
            "HTTP/1.1 101 Switching Protocols\r\n",
            "Connection: Upgrade\r\n",
            "Upgrade: websocket\r\n",
            "Sec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n",
            <<0x81, byte_size(greeting), greeting::binary>>
          ])

        send(owner, :sent)
        assert_receive :close
        :gen_tcp.close(client)
      end)

    {:ok, socket} = WebSocketConnection.connect({:http, "127.0.0.1", port}, "/", [])
    assert_receive :sent
    assert_receive {:tcp, _socket, _bytes} = message

    assert {:ok, socket, [:open, {:text, ^greeting}]} =
             WebSocketConnection.receive(socket, message)

    WebSocketConnection.close(socket)
    send(server.pid, :close)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  defp read_headers(socket, request) do
    if String.ends_with?(request, "\r\n\r\n") do
      request
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      read_headers(socket, request <> data)
    end
  end
end
