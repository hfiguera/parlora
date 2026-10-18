unless System.argv() == ["--live-keychain"],
  do: raise("Opt in with --live-keychain (54 bounded billable evaluations)")

Logger.configure(level: :warning)

{key, status} =
  System.cmd("security", ["find-generic-password", "-s", "typesafe_ai", "-a", "api_key", "-w"],
    stderr_to_stdout: true
  )

if status != 0, do: raise("Keychain credential retrieval failed; output suppressed")
key = String.trim_trailing(key, "\n")
if key == "", do: raise("Keychain returned an empty credential")

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {TypeSafe.Client,
       name: EvaluationClient,
       api_key: key,
       model: "jev-latest",
       timeout: 4_000,
       connect_timeout: 2_000,
       max_concurrency: 1,
       max_queue: 1,
       retry: [max_attempts: 1]}
    ],
    strategy: :one_for_one
  )

data = File.read!("cases.json")
cases = JSON.decode!(data)

schedule =
  Enum.flat_map(cases, fn c ->
    for pass <- 1..if(c["split"] == "held_out", do: 2, else: 1), do: {c, pass}
  end)

started = DateTime.utc_now() |> DateTime.to_iso8601()

rows =
  Enum.map(schedule, fn {c, pass} ->
    start = System.monotonic_time(:microsecond)

    response =
      TypeSafe.system_one(EvaluationClient,
        state: c["state"],
        questions: ParloraTypeSafeEval.questions(c["state"])
      )

    duration = (System.monotonic_time(:microsecond) - start) / 1_000

    row = %{
      id: c["id"],
      split: c["split"],
      pass: pass,
      duration_ms: duration,
      expected: c["expected"]
    }

    row =
      case response do
        {:ok, result} ->
          Map.merge(
            row,
            Map.merge(ParloraTypeSafeEval.score(c["expected"], result.answers), %{
              outcome: "ok",
              model: result.model,
              usage: result.usage
            })
          )

        {:error, error} ->
          Map.merge(row, %{outcome: Atom.to_string(error.kind), http_status: error.status})
      end

    IO.puts(
      "#{c["id"]} pass=#{pass} outcome=#{row.outcome} exact=#{Map.get(row, :exact, false)} ms=#{round(duration)}"
    )

    row
  end)

report = %{
  started_at: started,
  completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  package: "typesafe_ai 0.1.0",
  elixir: System.version(),
  otp: System.otp_release(),
  cases_sha256: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
  evaluator_sha256:
    :crypto.hash(:sha256, File.read!("lib/evaluation.ex")) |> Base.encode16(case: :lower),
  timeout_ms: 4_000,
  attempts: 1,
  concurrency: 1,
  summary: ParloraTypeSafeEval.summary(rows),
  by_split:
    Map.new(Enum.group_by(rows, & &1.split), fn {split, subset} ->
      {split, ParloraTypeSafeEval.summary(subset)}
    end),
  rows: rows
}

File.write!("results.json", JSON.encode!(report))
IO.puts(JSON.encode!(report.summary))
Supervisor.stop(supervisor)
