# Bounded live text-model qualification. Run from a Sagents-enabled standalone
# OrderDesk consumer through its private Keychain/environment launcher.
defmodule ParloraSagentsProbe do
  alias Parlora.{AdapterInit, BackendRequest, Event, Limits}
  alias Parlora.Backends.Sagents

  def run do
    output = System.fetch_env!("SAGENTS_PROBE_OUTPUT")
    File.mkdir_p!(Path.dirname(output))
    File.mkdir!(output)
    config = Application.fetch_env!(:order_desk, :sagents)

    plan = %{
      started_at: DateTime.utc_now(),
      qualification: :synthetic_text,
      sagents: to_string(Application.spec(:sagents, :vsn)),
      langchain: to_string(Application.spec(:langchain, :vsn)),
      model: config.model,
      sources: provenance(),
      reasoning_effort: config.reasoning_effort,
      elixir: System.version(),
      otp: System.otp_release(),
      mix_available: Code.ensure_loaded?(Mix),
      limitations: ["No human listening or voice provider in this text probe."]
    }

    File.write!(Path.join(output, "plan.json"), Jason.encode!(plan, pretty: true))

    init = %AdapterInit{
      session_id: "probe",
      adapter_id: "sagents",
      generation: 0,
      event_sink: self(),
      limits: %Limits{job_timeout_ms: 20_000}
    }

    {:ok, pid} =
      Sagents.start_link(init,
        agent: &OrderDesk.SagentsAgent.build(&1, config),
        completion_tool: "finish",
        max_runs: 6,
        result: &OrderDesk.SagentsAgent.result/1
      )

    requests =
      for {id, order, operation} <- [
            {"status", "123", "status"},
            {"independent", "124", "items"},
            {"multi-step", "124", "overview"}
          ] do
        %BackendRequest{
          id: id,
          task_id: id,
          task_revision: 1,
          provider_generation: 0,
          input: %{order: order, operation: operation}
        }
      end

    try do
      Enum.each(requests, fn request -> :ok = Sagents.submit(pid, request) end)
      outcomes = collect(length(requests), [], System.monotonic_time(:millisecond) + 25_000)
      passed = Enum.all?(outcomes, &(&1.type == :request_completed))

      report =
        Map.merge(plan, %{
          finished_at: DateTime.utc_now(),
          status: if(passed, do: :passed, else: :failed),
          outcomes: outcomes
        })

      File.write!(Path.join(output, "report.json"), Jason.encode!(report, pretty: true))
      IO.puts(Jason.encode!(%{status: report.status, model: config.model, outcomes: outcomes}))
      if not passed, do: raise("Live Sagents text qualification failed; evidence retained")
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp collect(0, outcomes, _deadline), do: Enum.reverse(outcomes)

  defp collect(remaining, outcomes, deadline) do
    receive do
      {:parlora_event, %Event{type: type} = event}
      when type in [:request_completed, :request_failed, :request_uncertain] ->
        entry = %{id: event.request_id, type: type, payload: normalize(event.payload)}
        collect(remaining - 1, [entry | outcomes], deadline)

      {:parlora_event, _event} ->
        collect(remaining, outcomes, deadline)
    after
      max(1, deadline - System.monotonic_time(:millisecond)) ->
        Enum.reverse([%{type: :probe_deadline, missing: remaining} | outcomes])
    end
  end

  defp normalize(value) when is_struct(value), do: normalize(Map.from_struct(value))

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalize(item)} end)

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

  defp provenance do
    source = System.get_env("SAGENTS_PROBE_SOURCE", File.cwd!())

    files =
      Path.wildcard(Path.join(source, "{lib,config}/**/*.{ex,exs}")) ++
        Path.wildcard(Path.join(source, "vendor/parlora/lib/**/*.ex")) ++
        Enum.map(
          ["mix.exs", "mix.lock", "vendor/parlora/mix.exs", "vendor/parlora/mix.lock"],
          &Path.join(source, &1)
        ) ++ [__ENV__.file]

    Map.new(files, fn file ->
      {Path.relative_to(file, source),
       Base.encode16(:crypto.hash(:sha256, File.read!(file)), case: :lower)}
    end)
  end
end

Logger.configure(level: :warning)
ParloraSagentsProbe.run()
