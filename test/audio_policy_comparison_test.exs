Code.require_file("../validation/playout-policy-20260921/policies.exs", __DIR__)

defmodule Parlora.AudioPolicyComparisonTest do
  use ExUnit.Case, async: true
  alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}
  alias Parlora.TestSupport.RecordedPlayout

  test "a shorter largest gap can hide extra later gaps in a complete recorded stream" do
    arrivals =
      "validation/pcm-overflow/refill-trial-arrivals.json"
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("arrivals")

    bytes = Enum.reduce(arrivals, 0, &(&1["bytes"] + &2))
    scenario = Scenarios.recorded(arrivals, Signal.pcm(div(bytes, 48)))
    recorded = Replay.run(scenario, 0, policy: RecordedPlayout)
    immediate = Replay.run(scenario, 0, policy: ImmediatePlayout)
    current = Replay.run(scenario)

    for result <- [recorded, immediate, current], do: assert(result.passed, inspect(result))
    assert [_gap] = recorded.gaps
    assert [_first, _second, _third] = immediate.gaps

    assert Enum.max_by(immediate.gaps, & &1.duration_us).duration_us <
             hd(recorded.gaps).duration_us

    assert immediate.inserted_silence_us == recorded.inserted_silence_us
    assert Enum.count_until(current.gaps, 2) <= 1
    assert current.inserted_silence_us <= recorded.inserted_silence_us
    assert current.startup_us <= 150_000
    assert current.max_playout_age_us <= recorded.max_playout_age_us
  end
end
