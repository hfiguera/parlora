defmodule OrderDesk.Application do
  use Application

  @impl true
  def prep_stop(state) do
    if Process.whereis(OrderDesk.TelnyxGate) do
      OrderDesk.TelnyxGate.drain()
      await_phone_commands(System.monotonic_time(:millisecond) + 9_000)
    end

    state
  end

  defp await_phone_commands(deadline) do
    status = OrderDesk.TelnyxGate.observations()

    if status.workers + status.queued > 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      await_phone_commands(deadline)
    end
  catch
    :exit, _stopped -> :ok
  end

  @impl true
  def start(_type, _args) do
    Application.put_env(:order_desk, :cookie_secret, Base.encode64(:crypto.strong_rand_bytes(64)))

    typesafe =
      case Application.get_env(:order_desk, :typesafe_api_key) do
        key when is_binary(key) and byte_size(key) > 0 ->
          [
            {TypeSafe.Client,
             name: OrderDesk.TypeSafe,
             api_key: key,
             model: "jev-1.13.0",
             timeout: 2_000,
             connect_timeout: 1_000,
             max_concurrency: 4,
             max_queue: 8,
             retry: [max_attempts: 1]}
          ]

        _missing ->
          []
      end

    Supervisor.start_link(
      [
        {OrderDesk.Store, path: Application.fetch_env!(:order_desk, :database)},
        OrderDesk.Interpretation,
        {Jido, name: OrderDesk.Jido},
        OrderDesk.BrowserGate
      ] ++ typesafe,
      strategy: :one_for_one,
      name: OrderDesk.Supervisor
    )
  end
end
