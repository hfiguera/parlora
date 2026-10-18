defmodule Parlora.SyntheticDeviceClockTest do
  use ExUnit.Case, async: false
  alias Parlora.Native.Device

  test "synthetic callbacks track elapsed time and stop with queues saturated" do
    {:ok, device} = Device.open_test(480)
    on_exit(fn -> Device.close(device) end)
    before = await_started(device, System.monotonic_time(:millisecond) + 1_000)
    started = System.monotonic_time(:microsecond)
    Process.sleep(1_500)
    after_stats = await_clock(device, before, started, started + 2_500_000)
    assert after_stats.input_queued <= 480
    assert after_stats.dropped > 0
    assert :ok = Device.close(device)
    stopped = Device.stats(device)
    assert stopped.stopped
    assert stopped.captured == stopped.rendered
  end

  # open_test/1 acknowledges resource creation before its worker enters the
  # synthetic clock loop. Measure rate only after callbacks have actually begun.
  defp await_started(device, deadline) do
    stats = Device.stats(device)

    if stats.rendered == 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(5)
      await_started(device, deadline)
    else
      assert stats.rendered > 0
      stats
    end
  end

  # A native callback can be descheduled at the instant BEAM samples it. Check
  # that the clock catches up, retaining the 50 ms bound and rejecting the former
  # sustained ~14% drift. Exact delayed-wakeup behavior is tested in Rust.
  defp await_clock(device, before, started, deadline) do
    stats = Device.stats(device)
    now = System.monotonic_time(:microsecond)
    elapsed = now - started
    rendered_us = (stats.rendered - before.rendered) * 1_000_000 / stats.output_rate

    if abs(rendered_us - elapsed) > 50_000 and now < deadline do
      Process.sleep(10)
      await_clock(device, before, started, deadline)
    else
      assert_in_delta rendered_us, elapsed, 50_000
      stats
    end
  end
end
