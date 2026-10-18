# Constructed snapshots, not a recording of the original model's decisions.
if Application.fetch_env!(:order_desk, :database) != ":memory:", do: raise("Use memory DB")
Code.require_file("policy_fixtures.exs", __DIR__)
alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.ContextTrigger
owner = self()
rows = for round <- 1..2, variant <- [:retry, :correct_candidate, :explicit_status, :status_tail, :progress, :retry_tail] do
  snapshot = if variant in [:progress, :retry_tail], do: RetryReplay.snapshot(:retry), else: RetryReplay.snapshot(variant)
  snapshot = case variant do
    :progress -> put_in(snapshot.transcripts, [%{hd(snapshot.transcripts) | delta: "Are you still checking?"} | tl(snapshot.transcripts)])
    :retry_tail ->
      snapshot = put_in(snapshot.tasks["lookup"].input.user_revision, 7)
      snapshot = put_in(snapshot.tasks["lookup"].input.request_text, "Just try")
      snapshot = %{snapshot | revision: 8}
      snapshot = put_in(snapshot.tasks["lookup"].context_wait, %{expired?: true, recheck_key: "8:verify"})
      put_in(snapshot.transcripts, [%{hd(snapshot.transcripts) | delta: " again", arrival_order: 8}, %{hd(snapshot.transcripts) | delta: "Just try"} | tl(snapshot.transcripts)])
    _ -> snapshot
  end
  {:ok, decisions} = AppPolicy.interpret(snapshot, %ContextTrigger{}, classify: fn input ->
    {:ok, response} = TypeSafe.system_one(OrderDesk.TypeSafe, state: input, questions: Interpretation.questions(input))
    answers = Map.new(response.answers, fn {k,v} -> {k, Map.take(v, [:choice, :probabilities])} end)
    result = Interpretation.interpret_answers(answers)
    send(owner, {:result, input, answers, result})
    result
  end)
  receive do
    {:result, input, answers, result} ->
      expected = case variant do
        :retry -> :start_task
        v when v in [:correct_candidate, :explicit_status] -> :supersede_task
        _ -> :associate_delegation
      end
      passed = hd(decisions).kind == expected
      row = %{round: round, variant: variant, passed: passed, input: input, answers: answers, judgment: inspect(result), decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))}
      IO.inspect(Map.take(row, [:round, :variant, :passed, :judgment]))
      row
  after 1000 -> raise "No judgment" end
end
File.write!(Path.join(__DIR__, "fixed-policy-results.json"), Jason.encode!(%{provenance: "Constructed snapshots; live TypeSafe classification, no business writes or audio call", rows: rows}, pretty: true) <> "\n")
if Enum.any?(rows, &(not &1.passed)), do: raise("Live interpretation control failed; see saved results")
