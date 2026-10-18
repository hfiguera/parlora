defmodule Parlora.AudioClockTest do
  use ExUnit.Case, async: true
  alias Parlora.AudioClock

  test "clock feedback is smoothed, bounded and independent for capture and playback" do
    initial = %{captured: 0, rendered: 0, input_rate: 48_000, output_rate: 48_000}
    {nil, clock} = AudioClock.sample(%AudioClock{}, initial, 0)
    assert {nil, ^clock} = AudioClock.sample(clock, initial, 1_000)
    stats = %{initial | captured: 240_120, rendered: 239_880}
    {{input, output}, clock} = AudioClock.sample(clock, stats, 5_000_000)
    assert input == -25
    assert output == -25
    extreme = %{stats | captured: 960_000, rendered: 100_000}
    {{input, output}, _clock} = AudioClock.sample(clock, extreme, 10_000_000)
    assert input in -1_000..1_000
    assert output in -1_000..1_000
  end
end
