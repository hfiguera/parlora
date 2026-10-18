unless System.argv() == ["--live"], do: raise("Use --live for 46 bounded JEV evaluations")
Logger.configure(level: :warning)
cases = File.read!(Path.join(__DIR__, "contextual-cases.json")) |> Jason.decode!()

rows =
  for item <- cases, pass <- 1..if(item["split"] == "contextual", do: 2, else: 1) do
    started = System.monotonic_time(:microsecond)
    {result, answers} = OrderDesk.ClarificationCoverage.evaluate(item["state"])
    elapsed = (System.monotonic_time(:microsecond) - started) / 1_000

    choice =
      case result do
        {:ok, value} -> value
        {:error, :uncertain} -> "uncertain"
        {:error, _} -> "error"
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
      pass: pass,
      split: item["split"],
      result: choice,
      expected: item["expected"],
      answer: answers,
      elapsed_ms: elapsed,
      baseline_suppresses: baseline.kind == :wait_for_context
    }

    IO.puts("#{row.id} pass=#{pass} result=#{choice} ms=#{round(elapsed)}")
    row
  end

File.write!(
  Path.join(__DIR__, "contextual-results.json"),
  Jason.encode!(
    %{
      configured_model: "jev-1.13.0",
      recorded_at: DateTime.utc_now(),
      rows: rows
    },
    pretty: true
  ) <> "\n"
)
