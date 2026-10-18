variant =
  case System.argv() do
    ["--live", "v1"] -> :v1
    ["--live", "v2"] -> :v2
    _ -> raise("Use --live v1 (34 requests) or --live v2 (42 requests)")
  end

Logger.configure(level: :warning)
directory = __DIR__
Code.require_file("judgment.exs", directory)
cases = File.read!(Path.join(directory, "cases.json")) |> Jason.decode!()
cases = if variant == :v1, do: Enum.reject(cases, &(&1["split"] == "fresh_held_out")), else: cases

rows =
  for item <- cases, pass <- 1..if(item["split"] == "held_out", do: 2, else: 1) do
    started = System.monotonic_time(:microsecond)
    {result, answer} = ParloraJevClarificationPilot.Judgment.evaluate(item["state"], variant)
    elapsed = (System.monotonic_time(:microsecond) - started) / 1_000

    choice =
      case result do
        {:ok, value} -> value
        {:error, :uncertain} -> "uncertain"
        {:error, _reason} -> "error"
      end

    snapshot = %Parlora.ContextSnapshot{
      application_context: %{voice_provider: :gemini},
      transcripts: [%{speaker: :assistant, delta: item["state"]["assistant"]}]
    }

    decision = %Parlora.ContextDecision{
      kind: :request_clarification,
      message: item["state"]["proposed"]["message"]
    }

    {:ok, [baseline]} = OrderDesk.Clarification.coordinate({:ok, [decision]}, snapshot)

    row = %{
      id: item["id"],
      split: item["split"],
      pass: pass,
      expected: item["expected"],
      result: choice,
      answer: answer,
      elapsed_ms: elapsed,
      baseline_suppresses: baseline.kind == :wait_for_context,
      passed: choice == item["expected"]
    }

    IO.puts("#{row.id} pass=#{pass} result=#{choice} correct=#{row.passed} ms=#{round(elapsed)}")
    row
  end

report = %{
  model: "jev-1.13.0",
  recorded_at: DateTime.utc_now(),
  rows: rows,
  passed: Enum.count(rows, & &1.passed),
  total: length(rows)
}

File.write!(
  Path.join(directory, "pilot-#{variant}.json"),
  Jason.encode!(report, pretty: true) <> "\n"
)

IO.puts("PILOT #{report.passed}/#{report.total}")
