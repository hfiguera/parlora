defmodule Parlora.Provider.WebSocketConnection do
  @moduledoc false
  alias Mint.{HTTP, WebSocket}

  def connect(endpoint, path, headers) do
    {scheme, host, port} = endpoint

    case HTTP.connect(scheme, host, port,
           protocols: [:http1],
           transport_opts: [timeout: 10_000, send_timeout: 1_000]
         ) do
      {:ok, conn} -> upgrade(conn, path, headers, scheme)
      _error -> {:error, :connect_failed}
    end
  end

  defp upgrade(conn, path, headers, scheme) do
    websocket_scheme = if scheme == :https, do: :wss, else: :ws

    case WebSocket.upgrade(websocket_scheme, conn, path, headers) do
      {:ok, conn, ref} ->
        {:ok, %{conn: conn, ref: ref, ws: nil, status: nil, headers: []}}

      _error ->
        HTTP.close(conn)
        {:error, :upgrade_failed}
    end
  end

  def send(socket, frame) do
    with {:ok, ws, bytes} <- WebSocket.encode(socket.ws, frame),
         {:ok, conn} <- WebSocket.stream_request_body(socket.conn, socket.ref, bytes) do
      {:ok, %{socket | conn: conn, ws: ws}}
    else
      _error -> {:error, :send_failed}
    end
  end

  def receive(socket, message) do
    case WebSocket.stream(socket.conn, message) do
      {:ok, conn, responses} -> decode(%{socket | conn: conn}, responses, [])
      {:error, _conn, _reason, _responses} -> {:error, :connection_lost}
      :unknown -> {:ok, socket, []}
    end
  end

  def close(nil), do: :ok
  def close(socket), do: HTTP.close(socket.conn)

  def consume(state, message, frame, fail) do
    case __MODULE__.receive(state.socket, message) do
      {:ok, socket, frames} -> Enum.reduce(frames, %{state | socket: socket}, frame)
      {:error, reason} -> fail.(state, reason)
    end
  end

  def json(state, bytes, event, fail) do
    case JSON.decode(bytes) do
      {:ok, message} when is_map(message) -> event.(message, state)
      _invalid -> fail.(state, :invalid_json)
    end
  end

  def command(%{status: :closed} = state, _command, _fail), do: state
  def command(state, command, fail), do: write(state, {:text, JSON.encode!(command)}, fail)

  def write(state, frame, fail) do
    case __MODULE__.send(state.socket, frame) do
      {:ok, socket} -> %{state | socket: socket}
      {:error, reason} -> fail.(state, reason)
    end
  end

  defp decode(socket, [], frames), do: {:ok, socket, Enum.reverse(frames)}

  defp decode(socket, [response | rest], frames) do
    case response(socket, response) do
      {:ok, next, more} -> decode(next, rest, Enum.reverse(more, frames))
      error -> error
    end
  end

  defp response(socket, {:status, _ref, status}), do: {:ok, %{socket | status: status}, []}
  defp response(socket, {:headers, _ref, headers}), do: {:ok, %{socket | headers: headers}, []}

  defp response(%{ws: nil, status: 101} = socket, {:done, _ref}) do
    case WebSocket.new(socket.conn, socket.ref, 101, socket.headers, mode: :active) do
      {:ok, conn, ws} -> {:ok, %{socket | conn: conn, ws: ws}, [:open]}
      _error -> {:error, :upgrade_failed}
    end
  end

  defp response(_socket, {:done, _ref}), do: {:error, :upgrade_rejected}

  defp response(%{ws: ws} = socket, {:data, _ref, data}) when ws != nil do
    if byte_size(data) + :erlang.external_size(ws) <= 1_048_576 do
      case WebSocket.decode(ws, data) do
        {:ok, ws, frames} -> {:ok, %{socket | ws: ws}, frames}
        _error -> {:error, :malformed_websocket}
      end
    else
      {:error, :oversized_websocket}
    end
  end

  defp response(socket, _response), do: {:ok, socket, []}
end
