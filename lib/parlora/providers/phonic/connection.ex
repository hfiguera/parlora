defmodule Parlora.Providers.Phonic.Connection do
  @moduledoc false
  alias Parlora.Provider.WebSocketConnection

  # A bare TCP close enters Phonic's abnormal-disconnect recovery window.
  # Normal application shutdown sends 1000 and gives its peer a short, bounded
  # opportunity to acknowledge, without consuming unrelated process messages.
  def close(nil, _timeout), do: :ok

  def close(%{ws: nil} = socket, timeout),
    do: close_transport(socket, System.monotonic_time(:millisecond) + min(timeout, 250))

  def close(socket, timeout) do
    deadline = System.monotonic_time(:millisecond) + min(timeout, 250)

    try do
      socket.conn.transport.setopts(Mint.HTTP.get_socket(socket.conn),
        send_timeout: min(timeout, 250),
        send_timeout_close: true
      )

      case WebSocketConnection.send(socket, {:close, 1000, ""}) do
        {:ok, next} -> await_close(next, deadline)
        {:error, _reason} -> :ok
      end
    after
      close_transport(socket, deadline)
    end

    :ok
  end

  # Mint's generic TLS close uses OTP's five-second default. Bound that second
  # handshake too: shut down both directions after the WebSocket exchange, then
  # release TLS state. This is deliberately confined to Phonic.
  defp close_transport(socket, deadline) do
    transport = Mint.HTTP.get_socket(socket.conn)

    if socket.conn.transport == Mint.Core.Transport.SSL do
      :ssl.shutdown(transport, :read_write)
      :ssl.close(transport, max(0, deadline - System.monotonic_time(:millisecond)))
      :ok
    else
      WebSocketConnection.close(socket)
    end
  end

  defp await_close(socket, deadline) do
    receive_close(socket, deadline, deadline - System.monotonic_time(:millisecond))
  end

  defp receive_close(_socket, _deadline, remaining) when remaining <= 0, do: :ok

  defp receive_close(socket, deadline, remaining) do
    transport = Mint.HTTP.get_socket(socket.conn)

    receive do
      {tag, ^transport, _data} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        case WebSocketConnection.receive(socket, message) do
          {:ok, next, frames} ->
            unless Enum.any?(frames, &match?({:close, _, _}, &1)),
              do: await_close(next, deadline)

          {:error, _reason} ->
            :ok
        end

      {tag, ^transport} when tag in [:tcp_closed, :ssl_closed] ->
        :ok
    after
      remaining -> :ok
    end
  end
end
