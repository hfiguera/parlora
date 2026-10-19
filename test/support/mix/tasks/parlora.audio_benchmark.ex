defmodule Mix.Tasks.Parlora.AudioBenchmark do
  @moduledoc "Deterministic PCM release gates; use MIX_ENV=test. See docs/audio-readiness.md."
  alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios}
  @shortdoc "Run deterministic audio release gates (MIX_ENV=test)"
  use Mix.Task

  @impl true
  def run(args) do
    if Mix.env() != :test, do: Mix.raise("Run with MIX_ENV=test")
    Mix.Task.run("app.start")
    {options, [], []} = OptionParser.parse(args, strict: [seeds: :integer, output: :string])
    seeds = Keyword.get(options, :seeds, 20)
    unless seeds in 1..1_000, do: Mix.raise("seeds must be 1..1000")

    scenarios = [
      :steady,
      :jitter,
      :burst,
      :variable,
      :scheduler,
      :shortage,
      :underproduction,
      :late_bursts,
      :repeated_shortages,
      :overflow
    ]

    rows =
      for seed <- 1..seeds, name <- scenarios do
        duration = if name in [:late_bursts, :repeated_shortages], do: 20_000, else: 3_000
        scenario = Scenarios.build(name, seed, duration)

        Replay.run(scenario, rem(seed, 10) * 1_000,
          playback_buffering: :adaptive,
          playback_recovery_ms: 120,
          startup_limit_ms: 210
        )
      end

    report = %{
      schema: 1,
      boundary: "virtual-clock production pipeline and PCM playout; no network or device",
      seeds: seeds,
      elixir: System.version(),
      erlang: List.to_string(:erlang.system_info(:system_version)),
      passed: Enum.all?(rows, & &1.passed),
      cases: rows,
      excluded: [
        "browser decoded audio",
        "physical device",
        "telephony",
        "live provider",
        "wall-clock load"
      ]
    }

    output = Keyword.get(options, :output, "/tmp/parlora-audio-benchmark.json")
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(report) <> "\n")
    Mix.shell().info("Audio gates: #{Enum.count(rows, & &1.passed)}/#{length(rows)}; #{output}")
    unless report.passed, do: Mix.raise("Audio acceptance gates failed; report preserved")
  end
end
