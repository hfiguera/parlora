defmodule Parlora.BrowserAudioPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parlora.TestSupport.AudioBenchmark.{BrowserSequence, Generators}

  test "partial frames join queued samples before padding the final packet" do
    BrowserSequence.run([{:write, 96}, {:write, 385}, {:tick, 30}])
  end

  test "partial staged samples remain source audio when the queue becomes empty" do
    BrowserSequence.run([{:write, 241}, {:tick, 30}])
  end

  property "random writes, ticks, clear, stop, resume and old epochs preserve the expected stream" do
    check all(commands <- Generators.commands(), max_runs: Generators.runs()) do
      # Guarantee at least one real interruption with queued/staged audio even
      # when shrinking removes every optional control from the random sequence.
      commands =
        [{:write, 480}, {:tick, 13}, :clear, :stale] ++
          commands ++ [:stop, {:write, 480}, {:tick, 1}, :resume, {:write, 239}]

      BrowserSequence.run(commands)
    end
  end
end
