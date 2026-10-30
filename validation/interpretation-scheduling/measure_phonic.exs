defmodule OrderDesk.InterpretationDiagnostic do
  def collect(rows) do
    receive do
      {:trace, _pid, :call, {OrderDesk.Interpretation, :trace, [record]}} ->
        collect([Map.put(record, :captured_at_ms, System.monotonic_time(:millisecond)) | rows])

      {:policy, stage, metadata} ->
        collect([
          %{
            kind: "policy_#{stage}",
            metadata: metadata,
            captured_at_ms: System.monotonic_time(:millisecond)
          }
          | rows
        ])

      {:snapshot, owner} ->
        send(owner, {:diagnostic_rows, Enum.reverse(rows)})
        collect(rows)
    end
  end

  def telemetry([:parlora, :policy, stage], _measurements, metadata, collector),
    do: send(collector, {:policy, stage, metadata})
end

collector = spawn(fn -> OrderDesk.InterpretationDiagnostic.collect([]) end)
:erlang.trace_pattern({OrderDesk.Interpretation, :trace, 1}, true, [:local])
:erlang.trace(:all, true, [:call, {:tracer, collector}])

:telemetry.attach_many(
  "interpretation-diagnostic",
  [[:parlora, :policy, :start], [:parlora, :policy, :stop]],
  &OrderDesk.InterpretationDiagnostic.telemetry/4,
  collector
)

script = Path.expand("../phonic/order_desk_delegation.exs", __DIR__)
source = File.read!(script) |> String.replace("unless report.passed, do: System.halt(1)", ":ok")
Code.eval_string(source, [], file: script)
:erlang.trace(:all, false, [:call])
:erlang.trace_pattern({OrderDesk.Interpretation, :trace, 1}, false, [:local])
:telemetry.detach("interpretation-diagnostic")
send(collector, {:snapshot, self()})

receive do
  {:diagnostic_rows, rows} ->
    report = %{stats: OrderDesk.Interpretation.stats(), rows: rows, synthetic: true}
    File.write!(System.fetch_env!("INTERPRETATION_REPORT"), JSON.encode!(report))
    IO.puts(JSON.encode!(%{interpretation_stats: report.stats, trace_rows: length(rows)}))
after
  1_000 -> raise "Diagnostic collector did not respond"
end
