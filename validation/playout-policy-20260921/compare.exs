Code.require_file("policies.exs", __DIR__)
alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios, Signal}
alias Parlora.TestSupport.RecordedPlayout

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
      do: Scenarios.build(name, 42, 20_000)

recorded =
  case System.get_env("PARLORA_ARRIVAL_SCHEDULE") do
    nil ->
      []

    path ->
      capture = path |> File.read!() |> Jason.decode!()
      bytes = Enum.sum(Enum.map(capture["arrivals"], & &1["bytes"]))
      [Scenarios.recorded(capture["arrivals"], Signal.pcm(div(bytes, 48)))]
  end

older =
  for {name, path, key} <- [
        {:recorded_short, "validation/pcm-overflow/starvation-evidence.json", "events"},
        {:recorded_long, "validation/pcm-overflow/refill-trial-arrivals.json", "arrivals"}
      ] do
    rows =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!(key)
      |> Enum.filter(&(&1["kind"] == "audio_received"))

    pcm = Signal.pcm(div(Enum.sum(Enum.map(rows, & &1["bytes"])), 48))
    %{Scenarios.recorded(rows, pcm) | name: name}
  end

scenarios =
  if System.get_env("PARLORA_POLICY_SCOPE") == "recorded",
    do: recorded ++ older,
    else: synthetic ++ recorded ++ older

results =
  for scenario <- scenarios,
      {policy, buffer} <- [
        {RecordedPlayout, 120},
        {ImmediatePlayout, 60},
        {ImmediatePlayout, 100},
        {ImmediatePlayout, 120},
        {FixedStartPlayout, 120},
        {Parlora.Playout, 120},
        {Refill40Playout, 120},
        {Refill60Playout, 120},
        {Refill100Playout, 120},
        {Refill100Wait40Playout, 120},
        {Refill120Wait60Playout, 120},
        {Refill120Wait120Playout, 120},
        {Refill100Wait120Playout, 120},
        {Refill140Wait120Playout, 120}
      ],
      phase <- [0, 5_000, 9_000] do
    result = Replay.run(scenario, phase, policy: policy, buffer_ms: buffer)
    Map.merge(result, %{policy: inspect(policy), buffer_ms: buffer})
  end

File.write!(
  System.fetch_env!("PARLORA_POLICY_REPORT"),
  Jason.encode!(
    %{
      baseline_commit: "78b1192",
      clock: "virtual; 1 ms steps, 10 ms playback, phases 0/5/9 ms",
      interpretation:
        "passed checks existing integrity/queue/normal-envelope gates; it does not approve a policy. Compare whole-stream gaps and latency separately.",
      results: results
    },
    pretty: true
  ) <> "\n"
)

for {{name, policy, buffer}, runs} <-
      Enum.group_by(results, &{&1.scenario, &1.policy, &1.buffer_ms}) |> Enum.sort() do
  IO.puts(
    Jason.encode!(%{
      scenario: name,
      policy: policy,
      buffer_ms: buffer,
      passed: Enum.count(runs, & &1.passed),
      cases: length(runs),
      max_startup_us: Enum.max(Enum.map(runs, & &1.startup_us)),
      max_silence_us: Enum.max(Enum.map(runs, & &1.inserted_silence_us)),
      max_gap_us:
        runs |> Enum.flat_map(& &1.gaps) |> Enum.map(& &1.duration_us) |> Enum.max(fn -> 0 end),
      max_age_us: Enum.max(Enum.map(runs, & &1.max_playout_age_us))
    })
  )
end
