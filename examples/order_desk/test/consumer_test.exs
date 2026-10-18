defmodule OrderDesk.ConsumerTest do
  use ExUnit.Case

  test "packaged native audio, application policy and Jido integrate through public APIs" do
    assert %{current_order: "124", jobs: 2, finalized: true} = OrderDesk.Smoke.run()
    await_cleanup(System.monotonic_time(:millisecond) + 5_000)
    assert Process.whereis(OrderDesk.Jido)
    assert Process.whereis(Parlora.Supervisor)
  end

  test "application startup does not require a credential or open a session" do
    # Earlier cases close sessions asynchronously. Require full supervision cleanup
    # before checking the idle application, regardless of randomized test order.
    await_cleanup(System.monotonic_time(:millisecond) + 5_000)
    assert %{active: 0} = DynamicSupervisor.count_children(Parlora.Sessions)
  end

  # OTP observation only: a coordinator DOWN precedes automatic supervisor removal.
  defp await_cleanup(deadline) do
    case DynamicSupervisor.count_children(Parlora.Sessions) do
      %{active: 0} ->
        :ok

      _closing ->
        assert System.monotonic_time(:millisecond) < deadline,
               "Session supervision did not finish cleanup"

        Process.sleep(5)
        await_cleanup(deadline)
    end
  end
end
