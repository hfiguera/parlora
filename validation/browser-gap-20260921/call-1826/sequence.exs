# Run in a separate Mix VM; never load this diagnostic into the live server.
# `observed` replaces Playout in this VM only to exercise the negative control.
alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios}

mode = List.first(System.argv()) || "current"

if mode == "observed" do
  Code.compiler_options(ignore_module_conflict: true)

  __DIR__
  |> Path.join("observed_playout.exs")
  |> File.read!()
  |> String.replace("defmodule RecordedAdaptivePlayout do", "defmodule Parlora.Playout do")
  |> Code.compile_string()
end

Mix.Task.run("app.start")

rows =
  for phase <- 0..9 do
    Replay.run(Scenarios.build(:repeated_shortages, 42, 20_000), phase * 1_000)
  end

path = List.last(System.argv())
File.write!(path, Jason.encode!(%{policy: mode, results: rows}, pretty: true) <> "\n")

if mode == "observed" do
  unless Enum.all?(rows, &(not &1.checks.recovery_delay)),
    do: raise("negative control did not fail the per-gap gate in every phase")
else
  unless Enum.all?(rows, & &1.passed), do: raise("corrected policy failed the full-sequence gate")
end
