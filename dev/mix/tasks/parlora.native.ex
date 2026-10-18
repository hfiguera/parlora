defmodule Mix.Tasks.Parlora.Native do
  @shortdoc "Check pinned native bindings with Rustfmt, Clippy, and Rust tests"
  @moduledoc "Runs native checks against the committed Cargo lockfiles."
  use Mix.Task

  @impl true
  def run(_args) do
    for manifest <- Path.wildcard("native/*/Cargo.toml") do
      check(["fmt", "--manifest-path", manifest, "--check"])

      check([
        "clippy",
        "--locked",
        "--manifest-path",
        manifest,
        "--all-targets",
        "--",
        "-D",
        "warnings"
      ])

      check(["test", "--locked", "--manifest-path", manifest])
    end
  end

  defp check(arguments) do
    case System.cmd("cargo", arguments, into: IO.stream(), stderr_to_stdout: true) do
      {_stream, 0} -> :ok
      {_stream, status} -> Mix.raise("Native check failed (exit #{status})")
    end
  end
end
