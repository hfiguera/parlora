defmodule Mix.Tasks.Parlora.Credence do
  @shortdoc "Check source with Credence without rewriting it"
  @moduledoc "Runs Credence with strict Unicode assumptions and fails on any finding."
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    findings =
      for path <-
            Path.wildcard("{lib,dev,test}/**/*.{ex,exs}") ++
              Path.wildcard("examples/support/**/*.{ex,exs}") ++
              Path.wildcard("examples/*.{ex,exs}"),
          issue <- Credence.Pattern.analyze(File.read!(path), assumptions: :strict) do
        {path, issue}
      end

    Enum.each(findings, fn {path, issue} -> Mix.shell().error("#{path}: #{inspect(issue)}") end)

    if findings != [], do: Mix.raise("Credence found #{length(findings)} issues")
    semantic_checks()
    Mix.shell().info("Credence: no findings (strict Unicode assumptions)")
  end

  defp semantic_checks do
    script = """
    [path] = System.argv()
    result = Credence.analyze(File.read!(path), assumptions: :strict)
    if result.issues != [] do
      IO.inspect({path, result.issues}, limit: :infinity)
      System.halt(1)
    end
    """

    # Credence recompiles and purges analyzed modules. Isolate that operation from
    # the running Mix task, loaded NIFs, and ExUnit's registered test processes.
    results =
      Task.async_stream(
        Path.wildcard("{lib,dev}/**/*.ex"),
        fn path ->
          System.cmd("mix", ["run", "--no-start", "--no-compile", "-e", script, "--", path],
            stderr_to_stdout: true,
            env: [{"ERL_FLAGS", "+S 2:2"}, {"MIX_ENV", Atom.to_string(Mix.env())}]
          )
        end,
        max_concurrency: 2,
        timeout: 60_000
      )

    Enum.each(results, fn
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, _status}} -> Mix.raise("Credence semantic analysis failed:\n#{output}")
      {:exit, reason} -> Mix.raise("Credence worker failed: #{inspect(reason)}")
    end)
  end
end
