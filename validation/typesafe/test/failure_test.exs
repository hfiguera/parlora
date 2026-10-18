defmodule ParloraTypeSafeFailureTest do
  use ExUnit.Case, async: true

  test "a stalled service returns timeout within the outer policy budget" do
    client = fixture(:stall)
    start = System.monotonic_time(:millisecond)
    assert {:error, %{kind: :timeout}} = evaluate(client, 100)
    assert System.monotonic_time(:millisecond) - start < 1_000
    assert_receive :peer_closed, 1_000
  end

  test "caller termination closes the outstanding HTTP/1 request" do
    client = fixture(:stall)
    {caller, monitor} = spawn_monitor(fn -> evaluate(client, 3_000) end)
    assert_receive :request_received, 1_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive :peer_closed, 1_000
    assert Process.alive?(client)
  end

  test "single-attempt rate limit is surfaced without a retry" do
    client = fixture(:rate_limit)
    assert {:error, %{kind: :http, status: 429}} = evaluate(client, 1_000)
    assert_receive :request_received
    refute_receive :unexpected_retry, 200
  end

  defp evaluate(client, timeout) do
    TypeSafe.system_one(client,
      state: "Synthetic fixture",
      questions: %{"test" => TypeSafe.noul("Is this a test?")},
      timeout: timeout,
      retry: [max_attempts: 1]
    )
  end

  defp fixture(mode) do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, _request_bytes} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :request_received)

        case mode do
          :stall ->
            await_close(socket, parent)

          :rate_limit ->
            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
              )

            :gen_tcp.close(socket)

            case :gen_tcp.accept(listener, 500) do
              {:ok, retry_socket} ->
                send(parent, :unexpected_retry)
                :gen_tcp.close(retry_socket)

              {:error, _reason} ->
                :ok
            end
        end
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    start_supervised!(
      {TypeSafe.Client,
       api_key: "synthetic-fixture-key",
       base_url: "http://127.0.0.1:#{port}",
       protocols: [:http1],
       max_concurrency: 1,
       max_queue: 1,
       retry: [max_attempts: 1]}
    )
  end

  defp await_close(socket, parent) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:error, :closed} -> send(parent, :peer_closed)
      {:ok, _body} -> await_close(socket, parent)
      {:error, _reason} -> :ok
    end
  end
end
