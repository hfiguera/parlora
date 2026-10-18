defmodule Parlora.AudioArrivalPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parlora.TestSupport.AudioBenchmark.{Generators, Replay}

  test "mixed 200 ms packets and jitter can exhaust an initially full cushion" do
    scenario = Generators.scenario([{200, 0, false}, {10, 17, false}], 1, :adverse)
    result = Replay.run(scenario, 1_000)
    assert result.passed
    assert result.inserted_silence_us > 0
  end

  for envelope <- [:normal, :adverse] do
    property "#{envelope} arrival sequences preserve samples, drain tails and clean up" do
      check all(
              packets <- Generators.packets(unquote(envelope)),
              tail <- integer(1..239),
              phase <- integer(0..9),
              max_runs: Generators.runs(),
              max_shrinking_steps: 200
            ) do
        result = Replay.run(Generators.scenario(packets, tail, unquote(envelope)), phase * 1_000)
        assert result.passed, inspect(result)
      end
    end
  end
end
