# Real text execution with bounded paid calls. No voice or human qualification.
defmodule ParloraLegionProbe do
  alias Parlora.{AdapterInit, BackendRequest, Event, Limits}

  def run do
    output = System.fetch_env!("BACKEND_PROBE_OUTPUT")
    File.mkdir_p!(Path.dirname(output))
    File.mkdir!(output)
    {adapter, options} = OrderDesk.Backend.selected()
    backend = Application.fetch_env!(:order_desk, :backend)
    config = Application.fetch_env!(:order_desk, backend)
    factory_key = if backend == :legion, do: :execution, else: :agent

    options =
      Keyword.update!(options, factory_key, fn factory ->
        fn request ->
          Process.put(:parlora_probe_id, request.id)
          factory.(request)
        end
      end)

    observer = self()

    event =
      if backend == :legion,
        do: [:legion, :llm, :request, :stop],
        else: [:langchain, :llm, :call, :stop]

    :ok =
      :telemetry.attach("parlora-backend-probe", event, &__MODULE__.usage/4, {observer, backend})

    plan = %{
      started_at: DateTime.utc_now(),
      backend: backend,
      version: to_string(Application.spec(backend, :vsn)),
      text_model: config.model,
      reasoning_effort: "none",
      qualification: "synthetic text; no human listening",
      voice_profile: %{model: "grok-voice-3.0", reasoning: "HIGH", used: false},
      interpreter: %{model: "jev-1.13.0", used: false},
      req_llm: if(Code.ensure_loaded?(ReqLLM), do: to_string(Application.spec(:req_llm, :vsn))),
      elixir: System.version(),
      otp: System.otp_release(),
      mix_available: Code.ensure_loaded?(Mix),
      sources: provenance(),
      max_job_ms: 20_000,
      repetitions: repetitions()
    }

    File.write!(Path.join(output, "plan.json"), Jason.encode!(plan, pretty: true))

    init = %AdapterInit{
      session_id: "probe",
      adapter_id: Atom.to_string(backend),
      generation: 0,
      event_sink: observer,
      limits: %Limits{job_timeout_ms: 20_000}
    }

    {:ok, pid} = adapter.start_link(init, options)

    try do
      entries =
        for repetition <- 1..repetitions(), operation <- ["status", "overview"] do
          id = "#{operation}-#{repetition}"

          request = %BackendRequest{
            id: id,
            task_id: id,
            task_revision: 1,
            provider_generation: 0,
            input: %{order: "124", operation: operation}
          }

          started = System.monotonic_time(:millisecond)
          :ok = adapter.submit(pid, request)
          collect(id, started, [], started + 25_000)
        end

      passed = Enum.all?(entries, &(&1.type == :request_completed))

      report =
        Map.merge(plan, %{
          finished_at: DateTime.utc_now(),
          outcomes: entries,
          status: if(passed, do: :passed, else: :failed)
        })

      File.write!(Path.join(output, "report.json"), Jason.encode!(report, pretty: true))
      IO.puts(Jason.encode!(%{backend: backend, status: report.status, outcomes: entries}))
      if not passed, do: raise("Bounded live probe failed; evidence retained")
    after
      :telemetry.detach("parlora-backend-probe")
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  # Select usage numbers only; never retain prompts, code, model structs or errors.
  def usage(_event, measurements, metadata, {observer, backend}) do
    id =
      if backend == :legion,
        do: apply(ProcessTree, :get, [:parlora_probe_id]),
        else: Process.get(:parlora_probe_id)

    usage =
      if backend == :legion,
        do: Map.get(metadata, :usage, %{}),
        else: Map.get(metadata, :token_usage)

    values =
      case usage do
        %{input: input, output: output} ->
          %{input_tokens: input, output_tokens: output}

        values when is_map(values) ->
          Map.take(values, ~w(input_tokens output_tokens total_tokens input output))

        _other ->
          %{}
      end

    send(
      observer,
      {:probe_usage, id,
       %{
         tokens: values,
         duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
       }}
    )
  end

  defp collect(id, started, usage, deadline) do
    receive do
      {:probe_usage, ^id, entry} ->
        collect(id, started, usage ++ [entry], deadline)

      {:parlora_event, %Event{request_id: ^id, type: type, payload: payload}}
      when type in [:request_completed, :request_failed, :request_uncertain] ->
        %{
          id: id,
          type: type,
          latency_ms: System.monotonic_time(:millisecond) - started,
          model_calls: length(usage),
          usage: usage,
          payload: normalize(payload)
        }

      {:parlora_event, _event} ->
        collect(id, started, usage, deadline)
    after
      max(1, deadline - System.monotonic_time(:millisecond)) ->
        %{id: id, type: :probe_deadline, usage: usage}
    end
  end

  defp repetitions,
    do:
      System.get_env("BACKEND_PROBE_REPETITIONS", "2") |> String.to_integer() |> min(3) |> max(1)

  defp normalize(value) when is_struct(value), do: normalize(Map.from_struct(value))

  defp normalize(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalize(item)} end)

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

  defp provenance do
    source = System.get_env("BACKEND_PROBE_SOURCE", File.cwd!())

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
ParloraLegionProbe.run()
