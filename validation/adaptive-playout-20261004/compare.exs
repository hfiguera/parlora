alias Parlora.{AudioFormat, Limits}
alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}

synthetic =
  for name <- [
        :steady,
        :jitter,
        :burst,
        :variable,
        :scheduler,
        :shortage,
        :underproduction,
        :late_bursts,
        :repeated_shortages
      ],
      seed <- 1..3,
      do: {Scenarios.build(name, seed, 20_000), %Limits{}}

recorded =
  for {name, file, provider} <- [
        {:gpt_live, "gpt-live-arrivals.json", Parlora.Providers.OpenAI},
        {:gemini, "gemini-arrivals.json", Parlora.Providers.Gemini},
        {:grok, "grok-arrivals.json", Parlora.Providers.Grok}
      ] do
    capture =
      Path.join("validation/playout-hardening-20261003", file) |> File.read!() |> Jason.decode!()

    true = capture["complete"]
    bytes = capture["received_bytes"]
    pcm = Signal.pcm(div(bytes + 47, 48)) |> binary_part(0, bytes)
    Code.ensure_loaded!(provider)

    overrides =
      if function_exported?(provider, :audio_limits, 1),
        do: provider.audio_limits(%AudioFormat{}),
        else: []

    {:ok, limits} = Limits.new(overrides)
    {%{Scenarios.recorded(capture["arrivals"], pcm) | name: name}, limits}
  end

regressions =
  for {name, file, key} <- [
        {:recorded_short, "validation/pcm-overflow/starvation-evidence.json", "events"},
        {:recorded_long, "validation/pcm-overflow/refill-trial-arrivals.json", "arrivals"}
      ] do
    arrivals =
      File.read!(file)
      |> Jason.decode!()
      |> Map.fetch!(key)
      |> Enum.filter(&(not Map.has_key?(&1, "kind") or &1["kind"] == "audio_received"))

    bytes = Enum.reduce(arrivals, 0, &(&1["bytes"] + &2))
    {%{Scenarios.recorded(arrivals, Signal.pcm(div(bytes, 48))) | name: name}, %Limits{}}
  end

policies = [
  {:legacy_120, []},
  {:fixed_120, [buffer_ms: 120, playback_buffering: :fixed, playback_recovery_ms: 120]},
  {:fixed_160, [buffer_ms: 160, playback_buffering: :fixed, playback_recovery_ms: 120]},
  {:fixed_200, [buffer_ms: 200, playback_buffering: :fixed, playback_recovery_ms: 120]},
  {:adaptive, [buffer_ms: 120, playback_buffering: :adaptive, playback_recovery_ms: 120]}
]

results =
  for {scenario, limits} <- synthetic ++ recorded ++ regressions,
      phase <- 0..9_000//1_000,
      {name, options} <- policies do
    result =
      Replay.run(scenario, phase, Keyword.merge([limits: limits, startup_limit_ms: 210], options))

    start = elem(hd(scenario.events), 0) + result.startup_us
    unavoidable = max(0, Scenarios.timeline(scenario).deficit_us - start)
    max_wait = result.gaps |> Enum.map(& &1.recovery_wait_us) |> Enum.max(fn -> 0 end)

    Map.merge(result, %{
      policy: name,
      unavoidable_silence_us: unavoidable,
      excess_silence_us: result.inserted_silence_us - unavoidable,
      max_recovery_wait_us: max_wait,
      safety_passed:
        result.passed and result.inserted_silence_us <= unavoidable + 130_000 and
          max_wait <= 130_000
    })
  end

summary =
  for {{scenario, policy}, rows} <-
        Enum.group_by(results, &{&1.scenario, &1.policy}) |> Enum.sort() do
    %{
      scenario: scenario,
      policy: policy,
      cases: length(rows),
      passed: Enum.all?(rows, & &1.safety_passed),
      max_startup_us: Enum.max(Enum.map(rows, & &1.startup_us)),
      max_silence_us: Enum.max(Enum.map(rows, & &1.inserted_silence_us)),
      max_gap_us:
        rows |> Enum.flat_map(& &1.gaps) |> Enum.map(& &1.duration_us) |> Enum.max(fn -> 0 end),
      max_gap_count: Enum.max(Enum.map(rows, &length(&1.gaps))),
      max_recovery_wait_us: Enum.max(Enum.map(rows, & &1.max_recovery_wait_us)),
      max_target_ms: Enum.max(Enum.map(rows, & &1.buffering.playback_target_ms))
    }
  end

report = %{
  passed: Enum.all?(results, & &1.safety_passed),
  baseline_commit: "83e0cb8",
  clock: "virtual; 1 ms transfers, 10 ms render, all ten render phases",
  results: results,
  summary: summary
}

File.write!(
  Path.join(__DIR__, "comparison.json.gz"),
  :zlib.gzip(Jason.encode!(report, pretty: true) <> "\n")
)

aggregate =
  report
  |> Map.delete(:results)
  |> Map.merge(%{cases: length(results), complete_results: "comparison.json.gz"})

File.write!(
  Path.join(__DIR__, "comparison-summary.json"),
  Jason.encode!(aggregate, pretty: true) <> "\n"
)

IO.puts(Jason.encode!(%{passed: report.passed, cases: length(results), summary: summary}))
unless report.passed, do: raise("Safety gate failed; complete comparison retained")
