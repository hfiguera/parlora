Code.require_file("baseline_pipeline.exs", __DIR__)
alias Parlora.{AudioFormat, AudioPipeline, Limits}
alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}
alias Parlora.Validation.BaselinePipeline

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
  for {name, filename, provider} <- [
        {:gpt_live, "gpt-live-arrivals.json", Parlora.Providers.OpenAI},
        {:gemini, "gemini-arrivals.json", Parlora.Providers.Gemini},
        {:grok, "grok-arrivals.json", Parlora.Providers.Grok}
      ] do
    Code.ensure_loaded!(provider)
    capture = Path.join(__DIR__, filename) |> File.read!() |> Jason.decode!()
    true = capture["complete"]
    bytes = capture["received_bytes"]
    pcm = Signal.pcm(div(bytes + 47, 48)) |> binary_part(0, bytes)

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

results =
  for {scenario, limits} <- synthetic ++ recorded ++ regressions,
      phase <- 0..9_000//1_000,
      pipeline <- [BaselinePipeline, AudioPipeline] do
    result = Replay.run(scenario, phase, pipeline: pipeline, limits: limits)

    start = elem(hd(scenario.events), 0) + result.startup_us
    unavoidable = max(0, Scenarios.timeline(scenario).deficit_us - start)
    max_wait = result.gaps |> Enum.map(& &1.recovery_wait_us) |> Enum.max(fn -> 0 end)
    excess = result.inserted_silence_us - unavoidable
    gate = result.passed and excess <= 130_000 and max_wait <= 130_000

    Map.merge(result, %{
      pipeline: inspect(pipeline),
      unavoidable_silence_us: unavoidable,
      excess_silence_us: excess,
      max_recovery_wait_us: max_wait,
      hardening_passed: gate,
      limit_configuration: Map.from_struct(limits)
    })
  end

summary =
  for {{scenario, pipeline}, rows} <-
        Enum.group_by(results, &{&1.scenario, &1.pipeline}) |> Enum.sort() do
    %{
      scenario: scenario,
      pipeline: pipeline,
      cases: length(rows),
      passed: Enum.all?(rows, & &1.hardening_passed),
      max_startup_us: Enum.max(Enum.map(rows, & &1.startup_us)),
      max_silence_us: Enum.max(Enum.map(rows, & &1.inserted_silence_us)),
      max_gap_us:
        rows |> Enum.flat_map(& &1.gaps) |> Enum.map(& &1.duration_us) |> Enum.max(fn -> 0 end),
      max_gap_count: Enum.max(Enum.map(rows, &length(&1.gaps))),
      max_excess_silence_us: Enum.max(Enum.map(rows, & &1.excess_silence_us)),
      max_admission_p99_us: Enum.max(Enum.map(rows, & &1.admission_p99_us)),
      max_age_us: Enum.max(Enum.map(rows, & &1.max_playout_age_us))
    }
  end

current = Enum.filter(results, &(&1.pipeline == inspect(AudioPipeline)))

report = %{
  baseline_commit: "de8ce59",
  clock: "virtual; 1 ms transfer steps, 10 ms rendered packets; phases 0..9 ms",
  sample_format: "mono PCM16LE/24 kHz",
  startup_buffer_ms: 120,
  explanation:
    "Complete arrival windows; all source samples including quiet count. The minimum possible inserted silence is max(receipt time minus preceding source duration) minus actual startup delay. Allow at most the configured recovery cap plus one render tick (130 ms) above that floor. Provider receipt is a local observation. This is not an audibility or remote-network attribution test.",
  passed: Enum.all?(current, & &1.hardening_passed),
  summary: summary,
  results: results
}

File.write!(
  System.fetch_env!("PARLORA_POLICY_REPORT"),
  Jason.encode!(report, pretty: true) <> "\n"
)

IO.puts(Jason.encode!(%{passed: report.passed, cases: length(current), summary: summary}))
unless report.passed, do: raise("Hardening gate failed; complete comparison preserved")
