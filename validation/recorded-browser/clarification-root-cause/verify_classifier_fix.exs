# Bounded live TypeSafe checks. Run in the standalone consumer with its key helper.
fresh = fn text, candidates ->
  %{
    caller_history: text,
    new_caller_text: text,
    handled_caller_input: nil,
    active_task: nil,
    recent_work: [],
    delivery_drafts: [],
    order_candidates: candidates
  }
end

followup = fn status, text ->
  task = %{order: "124", operation: "status", status: status}

  %{
    fresh.("Check order 124\n" <> text, ["124"])
    | new_caller_text: text,
      handled_caller_input: "Check order 124",
      active_task: task,
      recent_work: [task]
  }
end

cases = [
  {"fresh_123", fresh.("Check order one hundred twenty three", ["123"]), "status", "123"},
  {"fresh_124", fresh.("Check order one hundred twenty four", ["124"]), "status", "124"},
  {"missing_number", fresh.("Can you check my order?", []), "status", "unknown"},
  {"number_reply", fresh.("Can you check my order?\nOne two four", ["124"]), "status", "124"},
  {"running_followup", followup.(:submitted, "Are you still checking my order?"), "followup",
   "124"},
  {"completed_followup", followup.(:completed, "Did you check my order?"), "followup", "124"},
  {"items_followup", followup.(:completed, "What items are in that order?"), "items", "124"},
  {"correction",
   %{followup.(:completed, "No, sorry, go back to order 123") | order_candidates: ["123", "124"]},
   "status", "123"}
]

results =
  for {name, state, intent, order} <- cases do
    {:ok, response} =
      TypeSafe.system_one(OrderDesk.TypeSafe,
        state: state,
        questions: OrderDesk.Interpretation.questions(state)
      )

    judgment = OrderDesk.Interpretation.interpret_answers(response.answers)
    passed = judgment == {:ok, %{intent: intent, order: order}}

    %{
      case: name,
      passed: passed,
      input: state,
      judgment: inspect(judgment),
      answers:
        Map.new(response.answers, fn {key, answer} ->
          {key, Map.take(answer, [:choice, :probabilities])}
        end)
    }
  end

File.write!("/tmp/parlora-classifier-fix-results.json", Jason.encode!(results, pretty: true))
Enum.each(results, &IO.inspect(Map.take(&1, [:case, :passed, :judgment])))
unless Enum.all?(results, & &1.passed), do: raise("Live classification regression failed")
