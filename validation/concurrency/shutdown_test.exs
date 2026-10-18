Code.require_file(Path.expand("../interpretation-timeout/collector.exs", __DIR__))
ExUnit.start()

defmodule ParloraConcurrency.DiagnosticShutdownTest do
  use ExUnit.Case, async: false

  test "collector closes its file with telemetry running or already stopped" do
    {:ok, _} = Application.ensure_all_started(:telemetry)

    for stop_first <- [false, true] do
      path =
        Path.join(
          System.tmp_dir!(),
          "parlora-shutdown-#{System.unique_integer([:positive])}.jsonl"
        )

      {:ok, file} = File.open(path, [:write, :exclusive])
      on_exit(fn -> File.rm(path) end)

      :ok =
        :telemetry.attach(
          {ParloraInterpretationTrace, self()},
          [:typesafe, :request, :stop],
          &ParloraInterpretationTrace.event/4,
          self()
        )

      if stop_first, do: assert(:ok == Application.stop(:telemetry))
      assert :ok = ParloraInterpretationTrace.terminate(:shutdown, %{file: file})
      refute Process.alive?(file)
    end
  end
end
