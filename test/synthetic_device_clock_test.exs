defmodule Parlora.SyntheticDeviceClockTest do
  use ExUnit.Case, async: false
  alias Parlora.Native.Device

  test "synthetic callbacks track elapsed time and stop with queues saturated" do
    {:ok, device} = Device.open_test(480)
    on_exit(fn -> Device.close(device) end)
    before = Device.stats(device)
    started = System.monotonic_time(:microsecond)
    Process.sleep(1_500)
    after_stats = Device.stats(device)
    elapsed = System.monotonic_time(:microsecond) - started
    rendered_us = (after_stats.rendered - before.rendered) * 1_000_000 / after_stats.output_rate

    # Allow callback phase and scheduler noise, but reject the former ~14% drift.
    assert_in_delta rendered_us, elapsed, 50_000
    assert after_stats.input_queued <= 480
    assert after_stats.dropped > 0
    assert :ok = Device.close(device)
    stopped = Device.stats(device)
    assert stopped.stopped
    assert stopped.captured == stopped.rendered
  end
end
