defmodule Parlora.TestSupport.TwilioPeer do
  @moduledoc false
  alias Mint.{HTTP, WebSocket}

  def connect(port, path, signature) do
    connect_headers(port, path, [{"x-twilio-signature", signature}])
  end

  def connect_headers(port, path, request_headers) do
    {:ok, conn} = HTTP.connect(:http, "127.0.0.1", port, mode: :passive, protocols: [:http1])
    {:ok, conn, ref} = WebSocket.upgrade(:ws, conn, path, request_headers)
    {conn, status, headers} = handshake(conn, ref, nil, [])

    if status == 101 do
      {:ok, conn, websocket} = WebSocket.new(conn, ref, status, headers, mode: :passive)
      {:ok, %{conn: conn, ref: ref, websocket: websocket, messages: []}}
    else
      HTTP.close(conn)
      {:error, status}
    end
  end

  def send_message(peer, message) do
    {:ok, websocket, data} = WebSocket.encode(peer.websocket, {:text, Jason.encode!(message)})
    {:ok, conn} = WebSocket.stream_request_body(peer.conn, peer.ref, data)
    %{peer | websocket: websocket, conn: conn}
  end

  def receive_messages(peer, count) do
    if Enum.count_until(peer.messages, count) >= count do
      {messages, rest} = Enum.split(peer.messages, count)
      {messages, %{peer | messages: rest}}
    else
      {:ok, conn, responses} = WebSocket.recv(peer.conn, 0, 2_000)
      next = Enum.reduce(responses, %{peer | conn: conn}, &decode/2)
      receive_messages(next, count)
    end
  end

  def close(peer), do: HTTP.close(peer.conn)

  def finish_server_close(peer) do
    {:ok, conn, responses} = WebSocket.recv(peer.conn, 0, 2_000)

    {peer, frames} =
      Enum.reduce(responses, {%{peer | conn: conn}, []}, fn
        {:data, _ref, data}, {peer, frames} ->
          {:ok, websocket, decoded} = WebSocket.decode(peer.websocket, data)
          {%{peer | websocket: websocket}, frames ++ decoded}

        _response, result ->
          result
      end)

    case Enum.find(frames, &match?({:close, _, _}, &1)) do
      nil ->
        finish_server_close(peer)

      close ->
        {:ok, _websocket, data} = WebSocket.encode(peer.websocket, close)
        {:ok, _conn} = WebSocket.stream_request_body(peer.conn, peer.ref, data)
        :ok
    end
  end

  defp handshake(conn, ref, status, headers) do
    {:ok, conn, responses} = HTTP.recv(conn, 0, 2_000)
    {status, headers} = Enum.reduce(responses, {status, headers}, &response/2)

    if {:done, ref} in responses,
      do: {conn, status, headers},
      else: handshake(conn, ref, status, headers)
  end

  defp response({:status, _ref, status}, {_old, headers}), do: {status, headers}
  defp response({:headers, _ref, headers}, {status, _old}), do: {status, headers}
  defp response(_response, result), do: result

  defp decode({:data, _ref, data}, peer) do
    {:ok, websocket, frames} = WebSocket.decode(peer.websocket, data)
    messages = for {:text, json} <- frames, do: Jason.decode!(json)
    %{peer | websocket: websocket, messages: peer.messages ++ messages}
  end

  defp decode(_response, peer), do: peer
end
