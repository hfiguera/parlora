alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}

{baseline, 0} = System.cmd("git", ["show", "f3f7ad1195f3e6568f50d9173c7cdc0b286926d4:lib/parlora/playout.ex"])

Code.compile_string(
  String.replace(baseline, "defmodule Parlora.Playout do", "defmodule BeforeGreetingRecovery do")
)

captures = File.read!(Path.join(__DIR__, "arrivals.json")) |> Jason.decode!()

provider_captures =
  for {name, filename} <- [
        {"gpt-reference", "gpt-live-arrivals.json"},
        {"gemini-reference", "gemini-arrivals.json"},
        {"grok-reference", "grok-arrivals.json"}
      ] do
    data =
      File.read!(Path.join("validation/playout-hardening-20261003", filename)) |> Jason.decode!()

    %{
      "name" => name,
      "arrivals" => data["arrivals"],
      "complete" => data["complete"],
      "dropped_bytes" => 0
    }
  end

cases = captures["cases"] ++ provider_captures

results =
  for capture <- cases, phase <- 0..9_000//1_000 do
    true = capture["complete"]
    0 = capture["dropped_bytes"]
    bytes = Enum.reduce(capture["arrivals"], 0, &(&1["bytes"] + &2))
    pcm = Signal.pcm(div(bytes + 47, 48)) |> binary_part(0, bytes)
    scenario = Scenarios.recorded(capture["arrivals"], pcm)

    overrides =
      case capture["name"] do
        "gemini-reference" -> Parlora.Providers.Gemini.audio_limits()
        "grok-reference" -> Parlora.Providers.Grok.audio_limits()
        _openai -> []
      end

    {:ok, limits} = Parlora.Limits.new(overrides)

    options = [
      buffer_ms: 120,
      playback_buffering: :adaptive,
      startup_limit_ms: 210,
      limits: limits
    ]

    before = Replay.run(scenario, phase, Keyword.put(options, :policy, BeforeGreetingRecovery))
    after_change = Replay.run(scenario, phase, options)

    %{
      call: capture["name"],
      phase_us: phase,
      before: before,
      after: after_change,
      passed:
        before.passed and after_change.passed and
          after_change.startup_us == before.startup_us and
          Enum.all?(after_change.gaps, &(&1.recovery_wait_us <= 130_000))
    }
  end

report = %{
  baseline_commit: "f3f7ad1195f3e6568f50d9173c7cdc0b286926d4",
  description:
    "Complete captured receipt timings through production AudioPipeline and Playout, synthetic PCM, 1 ms virtual transfers and ten 10 ms render phases. Uninterrupted stream model; does not reproduce human hearing, speech boundaries or browser receiver conditions.",
  passed: Enum.all?(results, & &1.passed),
  results: results
}

File.write!(Path.join(__DIR__, "comparison.json"), Jason.encode!(report, pretty: true) <> "\n")

for {call, rows} <- Enum.group_by(results, & &1.call) |> Enum.sort() do
  IO.inspect(%{
    call: call,
    cases: length(rows),
    passed: Enum.all?(rows, & &1.passed),
    before_max_gaps: rows |> Enum.map(&length(&1.before.gaps)) |> Enum.max(),
    after_max_gaps: rows |> Enum.map(&length(&1.after.gaps)) |> Enum.max(),
    before_silence_ms:
      rows |> Enum.map(&div(&1.before.inserted_silence_us, 1_000)) |> Enum.min_max(),
    after_silence_ms:
      rows |> Enum.map(&div(&1.after.inserted_silence_us, 1_000)) |> Enum.min_max()
  })
end

unless report.passed, do: raise("Captured-call recovery validation failed")
