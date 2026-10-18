Code.require_file("../validation/speech-recovery-20261004/support.exs", __DIR__)

defmodule Parlora.SpeechRecoveryRecordedTest do
  use ExUnit.Case, async: true
  alias Parlora.TestSupport.AudioBenchmark.Scenarios

  @tag timeout: 180_000
  test "complete captured call shortens both reported speech stalls without increasing interruptions" do
    fixture =
      File.read!("validation/speech-recovery-20261004/gpt-live-call.json") |> Jason.decode!()

    pcm =
      Enum.map_join(fixture["levels"], fn [bytes, peak] ->
        :binary.copy(<<peak::little-signed-16>>, div(bytes, 2))
      end) <>
        :binary.copy(<<32_767::little-signed-16>>, div(fixture["unknown_tail_bytes"], 2))

    scenario = Scenarios.recorded(fixture["arrivals"], pcm)

    for phase <- [0, 1_000, 9_000] do
      baseline = run(scenario, phase, SpeechRecoveryReference)
      candidate = run(scenario, phase, Parlora.Playout)
      assert baseline.passed and candidate.passed
      assert baseline.startup_us == candidate.startup_us
      assert candidate.played_bytes == byte_size(pcm)
      assert candidate.inserted_silence_us <= baseline.inserted_silence_us + 200_000
      assert candidate.max_playout_age_us <= 400_000

      old = nonquiet_gaps(baseline, pcm, fixture["known_level_bytes"])
      new = nonquiet_gaps(candidate, pcm, fixture["known_level_bytes"])
      assert length(new) <= length(old)
      assert duration(new) <= duration(old)
      assert maximum(new) <= maximum(old)

      for position <- [422_400, 1_296_000] do
        before = Enum.find(old, &(&1.source_position_bytes == position))
        after_gap = Enum.find(new, &(&1.source_position_bytes == position))
        assert before != nil and after_gap != nil
        assert after_gap.duration_us <= before.duration_us - 40_000
      end
    end
  end

  defp run(scenario, phase, policy) do
    SpeechRecoveryReplay.run(scenario, phase,
      policy: policy,
      playback_buffering: :adaptive,
      startup_limit_ms: 210
    )
  end

  defp nonquiet_gaps(result, pcm, known) do
    Enum.filter(result.gaps, fn gap ->
      pos = gap.source_position_bytes
      pos >= 480 and pos + 480 <= known and peak(pcm, pos - 480) > 64 and peak(pcm, pos) > 64
    end)
  end

  defp peak(pcm, position) do
    for(<<sample::little-signed-16 <- binary_part(pcm, position, 480)>>, do: abs(sample))
    |> Enum.max()
  end

  defp duration(gaps), do: Enum.reduce(gaps, 0, &(&1.duration_us + &2))
  defp maximum(gaps), do: Enum.max(Enum.map(gaps, & &1.duration_us), fn -> 0 end)
end
