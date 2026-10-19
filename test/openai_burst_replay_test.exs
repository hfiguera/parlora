defmodule Parlora.OpenAIBurstReplayTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, Limits}
  alias Parlora.Providers.OpenAI
  alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios}

  @tag timeout: 180_000
  test "the complete ended-call arrival trace drains in order at every 10 ms render phase" do
    fixture =
      File.read!("validation/output-recovery-20261004/ended-call-envelope.json")
      |> JSON.decode!()

    known =
      Enum.map_join(fixture["levels"], fn [bytes, peak] ->
        :binary.copy(<<min(peak, 32_767)::little-signed-16>>, div(bytes, 2))
      end)

    pcm =
      known <> :binary.copy(<<32_767::little-signed-16>>, div(fixture["unknown_tail_bytes"], 2))

    scenario = Scenarios.recorded(fixture["arrivals"], pcm)
    {:ok, limits} = Limits.new(OpenAI.audio_limits(%AudioFormat{}))

    for phase <- 0..9 do
      result =
        Replay.run(scenario, phase * 1_000,
          limits: limits,
          playback_buffering: :adaptive,
          startup_limit_ms: 210
        )

      assert result.failure == nil
      assert result.checks.integrity
      assert result.checks.bounded
      assert result.played_bytes == byte_size(pcm)
      assert result.startup_us <= 210_000
    end
  end

  test "storage profiles scale with both formats while the channel cushion stays 200 ms" do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, limits} = Limits.new(OpenAI.audio_limits(format), format)
      assert limits.provider_audio_queue_bytes == AudioFormat.bytes_for_ms(format, 2_000)
      assert limits.provider_audio_max_age_ms == 3_000
      assert limits.audio_queue_bytes == AudioFormat.bytes_for_ms(format, 200)

      assert {:ok, custom} =
               Limits.new(
                 Keyword.merge(OpenAI.audio_limits(format),
                   provider_audio_queue_bytes: AudioFormat.bytes_for_ms(format, 500)
                 ),
                 format
               )

      assert custom.provider_audio_queue_bytes == AudioFormat.bytes_for_ms(format, 500)
    end
  end
end
