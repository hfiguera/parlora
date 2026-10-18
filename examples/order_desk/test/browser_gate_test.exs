defmodule OrderDesk.BrowserGateTest do
  use ExUnit.Case
  @moduletag capture_log: true
  alias Parlora.Channels.Browser

  test "bounded application admission and expired-session cleanup" do
    Application.put_env(:order_desk, :browser_offline, true)
    on_exit(fn -> Application.delete_env(:order_desk, :browser_offline) end)

    sessions =
      for _ <- 1..4 do
        assert {:ok, session} = OrderDesk.BrowserGate.start_session({Browser, signaling: self()})
        session
      end

    assert OrderDesk.BrowserGate.count() == 4

    assert {:error, %{code: :backpressure}} =
             OrderDesk.BrowserGate.start_session({Browser, signaling: self()})

    for session <- sessions, do: send(OrderDesk.BrowserGate, {:expire, session})
    await_cleanup(System.monotonic_time(:millisecond) + 5_000)
    assert OrderDesk.BrowserGate.count() == 0
  end

  defp await_cleanup(deadline) do
    if DynamicSupervisor.count_children(Parlora.Sessions).active > 0 or
         OrderDesk.BrowserGate.count() > 0 do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_cleanup(deadline)
    end
  end
end
