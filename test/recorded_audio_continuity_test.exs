defmodule Parlora.RecordedAudioContinuityTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, Limits}
  alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}

  # Complete calls across 30 virtual render phases exceed a minute on the floor pair.
  @tag timeout: 180_000
  test "complete provider windows retain every sample within bounded recovery at every phase" do
    for {file, provider} <- [
          {"gpt-live-arrivals.json", Parlora.Providers.OpenAI},
          {"gemini-arrivals.json", Parlora.Providers.Gemini},
          {"grok-arrivals.json", Parlora.Providers.Grok}
        ] do
      capture =
        Path.join("validation/playout-hardening-20261003", file)
        |> File.read!()
        |> Jason.decode!()

      assert capture["complete"]
      assert capture["received_bytes"] == capture["retained_bytes"]
      assert capture["dropped_bytes"] == 0
      scenario = scenario(capture["arrivals"])
      Code.ensure_loaded!(provider)

      overrides =
        if function_exported?(provider, :audio_limits, 1),
          do: provider.audio_limits(%AudioFormat{}),
          else: []

      {:ok, limits} = Limits.new(overrides)
      for phase <- 0..9_000//1_000, do: assert_complete(scenario, phase, limits)
    end
  end

  test "older regression windows satisfy the whole-stream bound across render phases" do
    for {file, key} <- [
          {"starvation-evidence.json", "events"},
          {"refill-trial-arrivals.json", "arrivals"}
        ] do
      arrivals =
        Path.join("validation/pcm-overflow", file)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!(key)
        |> Enum.filter(&(not Map.has_key?(&1, "kind") or &1["kind"] == "audio_received"))

      for phase <- 0..9_000//1_000, do: assert_complete(scenario(arrivals), phase, %Limits{})
    end
  end

  test "a fast five-second burst drains its entire tail beyond the final receipt" do
    pcm = Signal.pcm(5_000)
    scenario = Scenarios.recorded([%{"at_us" => 0, "bytes" => byte_size(pcm)}], pcm)

    {:ok, limits} =
      Limits.new(provider_audio_queue_bytes: 288_000, provider_audio_max_age_ms: 6_000)

    result = Replay.run(scenario, 0, limits: limits)
    assert result.passed, inspect(result)
    assert result.played_bytes == byte_size(pcm)
    assert result.finish_us >= 5_000_000
    assert result.inserted_silence_us == 0
  end

  defp scenario(arrivals) do
    bytes = Enum.reduce(arrivals, 0, &(&1["bytes"] + &2))
    pcm = Signal.pcm(div(bytes + 47, 48)) |> binary_part(0, bytes)
    Scenarios.recorded(arrivals, pcm)
  end

  defp assert_complete(scenario, phase, limits) do
    result = Replay.run(scenario, phase, limits: limits)
    assert result.passed, inspect(result)
    assert result.played_bytes == byte_size(scenario.pcm)
    start = elem(hd(scenario.events), 0) + result.startup_us
    unavoidable = max(0, Scenarios.timeline(scenario).deficit_us - start)
    assert result.inserted_silence_us <= unavoidable + 130_000
    assert Enum.all?(result.gaps, &(&1.recovery_wait_us <= 130_000))
  end
end
