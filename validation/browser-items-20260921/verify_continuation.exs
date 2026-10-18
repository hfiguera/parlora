# Bounded live classifier controls; no voice session or stored order changes.
Code.require_file("../browser-followup-20260921/policy_fixture.exs", __DIR__)
alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.ContextTrigger

base = FollowupReplay.snapshot(:separated_tail)

controls = [
  {"tail", " there", "handled_continuation", "123"},
  {"different_operation", "And the delivery status?", "status", "123"},
  {"different_order", "Actually, order 124", "items", "124"},
  {"missing_order", "What items are in another order?", "items", "unknown"},
  {"ambiguous_operation", "delivery", "unclear", "123"},
  {"new_draft", "Leave it at reception", "delivery", "123"},
  {"cancel", "Stop checking", "cancel", "123"}
]

cached =
  if "--cached" in System.argv(),
    do: Jason.decode!(File.read!(Path.join(__DIR__, "continuation-fix-results.json")))["rows"]

rows =
  for round <- 1..2, {name, text, intent, order} <- controls do
    [tail | rest] = base.transcripts
    snapshot = %{base | transcripts: [%{tail | delta: text} | rest]}
    input = FollowupReplay.input(snapshot)

    answers =
      if cached do
        row = Enum.find(cached, &(&1["round"] == round and &1["variant"] == name))
        true = Jason.decode!(Jason.encode!(input)) == row["input"]

        Map.new(row["answers"], fn {key, answer} ->
          {key, %{choice: answer["choice"], probabilities: answer["probabilities"]}}
        end)
      else
        {:ok, response} =
          TypeSafe.system_one(OrderDesk.TypeSafe,
            state: input,
            questions: Interpretation.questions(input)
          )

        response.answers
      end

    judgment = Interpretation.interpret_answers(answers)

    {:ok, decisions} =
      AppPolicy.interpret(snapshot, %ContextTrigger{}, classify: fn _ -> judgment end)

    pass? = judgment == {:ok, %{intent: intent, order: order}}
    kinds = Enum.map(decisions, & &1.kind)
    # Negative controls may clarify below threshold; they must never be swallowed
    # as continuations. Record exact semantic matches separately, including failures.
    safe? =
      case name do
        "tail" -> pass? and kinds == []
        "different_operation" -> pass? and kinds == [:start_task]
        "new_draft" -> pass? and kinds == [:wait_for_context]
        _ -> kinds == [:request_clarification] or (pass? and kinds != [])
      end

    row = %{
      round: round,
      variant: name,
      input: input,
      answers: Map.new(answers, fn {k, a} -> {k, Map.take(a, [:choice, :probabilities])} end),
      judgment: inspect(judgment),
      decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input])),
      exact_judgment: pass?,
      continuation_guard_passed: safe?
    }

    IO.inspect(
      Map.take(row, [
        :round,
        :variant,
        :judgment,
        :decisions,
        :exact_judgment,
        :continuation_guard_passed
      ]),
      limit: :infinity
    )

    row
  end

File.write!(
  Path.join(__DIR__, "continuation-fix-results.json"),
  Jason.encode!(
    %{
      provenance: "Constructed post-fix TypeSafe controls, not a replay of the original session.",
      rows: rows
    },
    pretty: true
  ) <> "\n"
)

true = Enum.all?(rows, & &1.continuation_guard_passed)
