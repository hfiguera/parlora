# Synthetic-only diagnostic wrapper; never captures credentials or encoded audio.
defmodule Parlora.OrderDeskLiveTrace do
  def collect(records, started) do
    receive do
      {:trace, _pid, :call, {Parlora.Event, :emit, [_init, source, type, payload, fields]}} ->
        row = %{
          direction: "event",
          source: source,
          type: type,
          payload: clean(payload),
          fields: clean(fields)
        }

        collect([stamp(row, started) | records], started)

      {:trace, _pid, :call, {module, function, args}} ->
        {message, state} =
          case {function, args} do
            {:event, [message, state]} -> {message, state}
            {:transmit, [state, message]} -> {message, state}
          end

        if audio?(message) do
          collect(records, started)
        else
          flags =
            Map.take(state, [
              :status,
              :speech,
              :caller_speaking,
              :auto_response_pending,
              :continuation?,
              :output_blocked,
              :response_watch,
              :activity
            ])

          row = %{
            direction: function,
            provider: module,
            payload: clean(message),
            state: clean(flags)
          }

          collect([stamp(row, started) | records], started)
        end

      {:snapshot, owner} ->
        send(owner, {:trace_rows, Enum.reverse(records)})
    end
  end

  defp stamp(row, started), do: Map.put(row, :ms, System.monotonic_time(:millisecond) - started)
  defp audio?(%{"type" => "audio_chunk"}), do: true
  defp audio?(%{type: "audio_chunk"}), do: true
  defp audio?(%{realtimeInput: %{audio: _audio}}), do: true
  defp audio?({:audio, _bytes}), do: true
  defp audio?(_message), do: false
  defp clean(%_{} = value), do: value |> Map.from_struct() |> clean()

  defp clean(value) when is_map(value) do
    Map.new(value, fn {key, val} ->
      value =
        if key in [
             "data",
             :data,
             "audio",
             :audio,
             :api_key,
             "api_key",
             "newHandle",
             :timer,
             :token
           ],
           do: "[omitted]",
           else: clean(val)

      {key, value}
    end)
  end

  defp clean(value) when is_tuple(value), do: value |> Tuple.to_list() |> clean()
  defp clean(value) when is_list(value), do: Enum.map(value, &clean/1)

  defp clean(value) when is_pid(value) or is_reference(value) or is_function(value),
    do: "[runtime]"

  defp clean(value), do: value
end

if revision = System.get_env("ORDER_DESK_REPLAY_REVISION") do
  Code.compiler_options(ignore_module_conflict: true)
  :ok = Supervisor.terminate_child(OrderDesk.Supervisor, OrderDesk.Interpretation)

  for file <- ["order_desk.ex", "order_desk/app_policy.ex", "order_desk/interpretation.ex"] do
    {:ok, source} =
      case System.cmd("git", ["show", "#{revision}:examples/order_desk/lib/#{file}"]) do
        {source, 0} -> {:ok, source}
        _ -> raise "Cannot load baseline #{revision}"
      end

    Code.compile_string(source, "baseline/#{file}")
  end

  {:ok, _pid} = Supervisor.restart_child(OrderDesk.Supervisor, OrderDesk.Interpretation)
end

for module <- [Parlora.Event, Parlora.Providers.Phonic, Parlora.Providers.Gemini],
    do: Code.ensure_loaded!(module)

collector =
  spawn(fn -> Parlora.OrderDeskLiveTrace.collect([], System.monotonic_time(:millisecond)) end)

patterns =
  for module <- [Parlora.Providers.Phonic, Parlora.Providers.Gemini],
      function <- [:event, :transmit],
      do: {module, function, 2}

patterns = [{Parlora.Event, :emit, 5} | patterns]
for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [:local])
:erlang.trace(:all, true, [:call, {:tracer, collector}])
System.put_env("ORDER_DESK_LIVE_IMPORT", "1")
Code.require_file(Path.join(__DIR__, "order_desk_live.exs"))
System.delete_env("ORDER_DESK_LIVE_IMPORT")
[directory, output] = System.argv()
report = Parlora.OrderDeskInterpretationLive.run(directory, output)
:erlang.trace(:all, false, [:call])
for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
ref = :erlang.trace_delivered(:all)

receive do
  {:trace_delivered, :all, ^ref} -> :ok
after
  5_000 -> raise "Trace delivery timed out"
end

send(collector, {:snapshot, self()})

receive do
  {:trace_rows, rows} ->
    output = List.last(System.argv()) <> ".trace.json"

    File.write!(
      output,
      JSON.encode!(%{baseline: System.get_env("ORDER_DESK_REPLAY_REVISION"), rows: rows})
    )

    IO.puts(JSON.encode!(%{trace: output, rows: length(rows)}))
after
  5_000 -> raise "Trace collection timed out"
end

unless report.passed, do: System.halt(1)
