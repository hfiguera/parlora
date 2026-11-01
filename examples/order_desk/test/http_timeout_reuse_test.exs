defmodule OrderDesk.HTTPTimeoutReuseTest do
  use ExUnit.Case, async: true

  test "an HTTP receive timeout cannot poison the next pooled request with a stale response" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    observer = self()
    start_supervised!({Task, fn -> serve(listener, observer) end})
    name = __MODULE__.Finch
    start_supervised!({Finch, name: name, pools: %{default: [size: 1, count: 1]}})
    url = "http://127.0.0.1:#{port}"

    assert {:error, %Finch.TransportError{reason: :timeout}} =
             Finch.build(:get, url <> "/slow") |> Finch.request(name, receive_timeout: 50)

    assert_receive :first_request_received

    assert {:ok, %Finch.Response{status: 200, body: "fresh"}} =
             Finch.build(:get, url <> "/fresh") |> Finch.request(name, receive_timeout: 2_000)

    assert_receive :fresh_connection
  end

  defp serve(listener, observer) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    {:ok, _request} = headers(socket)
    send(observer, :first_request_received)

    case headers(socket) do
      {:ok, _next_request} ->
        # An unfinished response on a reused HTTP/1 socket belongs to the old
        # Mint request reference, even after another request has been submitted.
        :gen_tcp.send(socket, response("stale") <> response("fresh"))
        :gen_tcp.close(socket)

      {:error, :closed} ->
        {:ok, fresh} = :gen_tcp.accept(listener, 5_000)
        {:ok, _request} = headers(fresh)
        send(observer, :fresh_connection)
        :gen_tcp.send(fresh, response("fresh"))
        :gen_tcp.close(fresh)
    end
  end

  defp headers(socket, received \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        received = received <> data

        if String.contains?(received, "\r\n\r\n"),
          do: {:ok, received},
          else: headers(socket, received)

      error ->
        error
    end
  end

  defp response(body),
    do: "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
end
