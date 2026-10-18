# Run in the unpacked OrderDesk consumer, with its normal TypeSafe credential.
# Only synthetic read-only comparison requests are sent; no orders are executed.
Logger.configure(level: :error)
[fixtures, output] = System.argv()
cases = fixtures |> File.read!() |> Jason.decode!()

results =
  for item <- cases, model <- ["jev-1.13.0", "jev-1.14.0"] do
    started = System.monotonic_time(:millisecond)

    reply =
      TypeSafe.system_one(OrderDesk.TypeSafe,
        model: model,
        state: item["state"],
        questions: OrderDesk.ClarificationCoverage.questions(),
        timeout: 700,
        retry: [max_attempts: 1]
      )

    {result, answers, returned} =
      case reply do
        {:ok, response} ->
          {OrderDesk.ClarificationCoverage.interpret_pair(response.answers),
           Map.new(response.answers, fn {key, value} ->
             {key, Map.take(value, [:choice, :probabilities])}
           end), response.model}

        {:error, error} ->
          {{:error, error.kind}, %{}, nil}
      end

    choice =
      case result do
        {:ok, value} -> value
        {:error, :uncertain} -> "uncertain"
        {:error, reason} -> "error:#{reason}"
      end

    record = %{
      name: item["id"],
      requested_model: model,
      returned_model: returned,
      expected: item["expected"],
      result: choice,
      passed: choice == item["expected"] and returned == model,
      incorrect_suppression: choice == "covered" and item["expected"] != "covered",
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      answers: answers
    }

    IO.puts(Jason.encode!(Map.drop(record, [:answers])))
    record
  end

File.write!(
  output,
  Jason.encode!(
    %{
      method:
        "All 38 existing contextual clarification fixtures; sequential paired requests with the application 700 ms deadline, 0.85 confidence gate and no retries.",
      recorded_at: DateTime.utc_now(),
      fixtures_sha256: :crypto.hash(:sha256, File.read!(fixtures)) |> Base.encode16(case: :lower),
      results: results
    },
    pretty: true
  ) <> "\n"
)

if Enum.any?(results, & &1.incorrect_suppression), do: System.halt(1)
