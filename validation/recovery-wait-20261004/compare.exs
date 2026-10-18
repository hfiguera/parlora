alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}

source = File.read!(Path.join(__DIR__, "reference.exs"))

policies =
  for ceiling <- [20, 40, 50, 60, 80, 120] do
    module = Module.concat(["RecoveryWait#{ceiling}"])

    source =
      source
      |> String.replace("defmodule RecoveryWaitReference do", "defmodule #{inspect(module)} do")
      |> String.replace(
        "maximum = min(shortage + 20_000, cap)",
        "maximum = min(shortage + 20_000, cap)\n" <>
          "    maximum = if state.target && shortage <= cap, do: min(maximum, #{ceiling * 1_000}), else: maximum"
      )

    Code.compile_string(source)
    {ceiling, module}
  end

manual =
  File.read!("validation/greeting-recovery-20261004/arrivals.json")
  |> Jason.decode!()
  |> Map.fetch!("cases")

manual = manual ++ [File.read!(Path.join(__DIR__, "arrivals.json")) |> Jason.decode!()]

recorded =
  for {name, filename, overrides} <- [
        {"gpt-reference", "gpt-live-arrivals.json", []},
        {"gemini-reference", "gemini-arrivals.json", Parlora.Providers.Gemini.audio_limits()},
        {"grok-reference", "grok-arrivals.json", Parlora.Providers.Grok.audio_limits()}
      ] do
    capture =
      File.read!(Path.join("validation/playout-hardening-20261003", filename)) |> Jason.decode!()

    {:ok, limits} = Parlora.Limits.new(overrides)
    {Map.put(capture, "name", name), limits}
  end

captures = Enum.map(manual, &{&1, %Parlora.Limits{}}) ++ recorded

scenarios =
  for {capture, limits} <- captures do
    true = capture["complete"]
    bytes = Enum.reduce(capture["arrivals"], 0, &(&1["bytes"] + &2))
    pcm = Signal.pcm(div(bytes + 47, 48)) |> binary_part(0, bytes)
    {capture["name"], Scenarios.recorded(capture["arrivals"], pcm), limits}
  end

synthetic =
  for name <- [:steady, :jitter, :shortage, :underproduction, :late_bursts, :repeated_shortages],
      do: {Atom.to_string(name), Scenarios.build(name, 42, 20_000), %Parlora.Limits{}}

results =
  for {name, scenario, limits} <- scenarios ++ synthetic,
      phase <- 0..9_000//1_000,
      {ceiling, policy} <- policies do
    result =
      Replay.run(scenario, phase,
        policy: policy,
        playback_buffering: :adaptive,
        startup_limit_ms: 210,
        limits: limits
      )

    %{
      scenario: name,
      ceiling_ms: ceiling,
      phase_us: phase,
      result: result
    }
  end

summary =
  for {{scenario, ceiling}, cases} <-
        Enum.group_by(results, &{&1.scenario, &1.ceiling_ms}) |> Enum.sort() do
    gaps = Enum.flat_map(cases, & &1.result.gaps)

    %{
      scenario: scenario,
      ceiling_ms: ceiling,
      cases: length(cases),
      passed: Enum.all?(cases, & &1.result.passed),
      gaps_range: cases |> Enum.map(&length(&1.result.gaps)) |> Enum.min_max() |> Tuple.to_list(),
      large_gaps_range:
        cases
        |> Enum.map(fn c -> Enum.count(c.result.gaps, &(&1.duration_us >= 100_000)) end)
        |> Enum.min_max()
        |> Tuple.to_list(),
      max_gap_us: gaps |> Enum.map(& &1.duration_us) |> Enum.max(fn -> 0 end),
      max_wait_us: gaps |> Enum.map(& &1.recovery_wait_us) |> Enum.max(fn -> 0 end),
      total_silence_range_us:
        cases |> Enum.map(& &1.result.inserted_silence_us) |> Enum.min_max() |> Tuple.to_list()
    }
  end

report = %{
  description:
    "Ordinary-shortage adaptive wait ceilings only; severe stalls and fixed buffering retain the reference rule. Production AudioPipeline, synthetic PCM, 1 ms virtual transfers, ten render phases. Whole-stream gaps include quiet source boundaries; they are not audible-defect counts.",
  passed: Enum.all?(results, & &1.result.passed),
  cases: length(results),
  summary: summary,
  results: results
}

File.write!(Path.join(__DIR__, "comparison.json.gz"), :zlib.gzip(Jason.encode!(report) <> "\n"))

File.write!(
  Path.join(__DIR__, "summary.json"),
  Jason.encode!(Map.delete(report, :results), pretty: true) <> "\n"
)

IO.puts(Jason.encode!(Map.take(report, [:passed, :cases, :summary])))
unless report.passed, do: raise("Wait-ceiling safety comparison failed")
