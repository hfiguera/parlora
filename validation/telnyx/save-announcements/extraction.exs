base = %{
  caller_history: "Check order 124\nWhat items are in that order?",
  latest_caller_segment: "",
  new_caller_text: "",
  handled_caller_input: "What items are in that order?",
  active_task: %{order: "124", operation: "items", status: :completed},
  clarification_reply: nil,
  delivery_drafts: [],
  recent_work: [%{order: "124", operation: "items", status: :completed}],
  order_candidates: ["124"]
}

for {phrase, expected} <- [
      {"Okay, let's change that. I want to change to, let with my neighbor", "delivery"},
      {"Let me check the page", "none"}
    ] do
  state = %{
    base
    | caller_history: base.caller_history <> "\n" <> phrase,
      new_caller_text: phrase,
      latest_caller_segment: phrase
  }

  {:ok, response} =
    TypeSafe.system_one(OrderDesk.TypeSafe,
      state: state,
      questions: OrderDesk.Interpretation.questions(state)
    )

  judgment = OrderDesk.Interpretation.interpret_answers(response.answers)

  IO.inspect(%{
    phrase: phrase,
    judgment: judgment,
    literal: OrderDesk.Speech.delivery(phrase),
    answers:
      Map.new(response.answers, fn {key, answer} ->
        {key, Map.take(answer, [:choice, :probabilities])}
      end)
  })

  unless match?({:ok, %{intent: ^expected}}, judgment), do: raise("Unexpected classification")
  if expected == "delivery", do: "let with my neighbor" = OrderDesk.Speech.delivery(phrase)
end
