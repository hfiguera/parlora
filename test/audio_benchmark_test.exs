defmodule Parlora.AudioBenchmarkTest do
  # Replay hundreds of seconds of audio outside tests with real-time deadlines.
  use ExUnit.Case, async: false
  alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios}

  test "declared arrival envelope preserves PCM without adding gaps" do
    for name <- [:steady, :jitter, :burst, :variable, :scheduler], seed <- 1..3 do
      result = Replay.run(Scenarios.build(name, seed), rem(seed, 10) * 1_000)
      assert result.passed, inspect(result)
    end
  end

  test "a non-frame-sized tail drains exactly without padding source accounting" do
    result = Replay.run(Scenarios.build(:variable, 73, 3_007), 9_000)
    assert result.passed, inspect(result)
    assert result.played_bytes == 3_007 * 48
  end

  test "small cumulative provider delays stay bounded without losing or duplicating PCM" do
    for phase <- 0..9 do
      result = Replay.run(Scenarios.build(:late_bursts, 42, 20_000), phase * 1_000)
      assert result.passed, inspect(result)
      assert result.inserted_silence_us > 0
      # 570 ms accumulated lateness exceeds the initial cushion; finite queues
      # cannot remove source underproduction. Bound added delay, not gap count.
      assert result.inserted_silence_us <= 600_000
      assert result.played_bytes == 20_000 * 48
    end
  end

  test "out-of-envelope shortages preserve source and overload is explicit" do
    for name <- [:shortage, :underproduction, :overflow] do
      result = Replay.run(Scenarios.build(name, 42))
      assert result.passed, inspect(result)
    end
  end

  test "repeated late packets across quiet and nonquiet PCM do not amplify recovery waits" do
    for phase <- 0..9 do
      scenario = Scenarios.build(:repeated_shortages, 42, 20_000)
      result = Replay.run(scenario, phase * 1_000)
      assert result.passed, inspect(result)
      assert Enum.count_until(result.gaps, 6) == 6

      ordinary = Enum.filter(result.gaps, &(&1.source_unavailable_us <= 80_000))
      assert Enum.count_until(ordinary, 3) == 3
      assert Enum.all?(ordinary, &(&1.recovery_wait_us <= 30_000))
      assert result.played_bytes == byte_size(scenario.pcm)
    end
  end

  test "adaptive recovery trades fewer repeated gaps for bounded additional headroom" do
    scenario = Scenarios.build(:repeated_shortages, 42, 20_000)

    for phase <- [0, 5_000, 9_000] do
      fixed = Replay.run(scenario, phase)

      adaptive =
        Replay.run(scenario, phase,
          playback_buffering: :adaptive,
          playback_recovery_ms: 120,
          startup_limit_ms: 210
        )

      assert adaptive.passed, inspect(adaptive)
      assert adaptive.buffering.playback_target_ms == 200
      assert Enum.count_until(adaptive.gaps, 100) < Enum.count_until(fixed.gaps, 100)
      assert adaptive.inserted_silence_us <= fixed.inserted_silence_us + 120_000

      assert Enum.all?(adaptive.gaps, fn gap ->
               gap.recovery_wait_us <=
                 if(gap.source_unavailable_us == 0, do: 210_000, else: 130_000)
             end)

      assert adaptive.played_bytes == byte_size(scenario.pcm)
    end
  end
end
