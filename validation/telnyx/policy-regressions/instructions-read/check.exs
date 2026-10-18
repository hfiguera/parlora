alias OrderDesk.{AppPolicy, Interpretation}

base = %{
  caller_history: "Check order 124\nActually, I mean 123\nDo you know what items are there",
  latest_caller_segment: "",
  active_task: %{order: "123", operation: "items", status: :completed},
  new_caller_text: "",
  handled_caller_input: "Do you know what items are there",
  clarification_reply: nil,
  delivery_drafts: [],
  recent_work: [%{order: "123", operation: "items", status: :completed}],
  order_candidates: ["124", "123"]
}

for {phrase, intent, target} <- [
      {"Okay, and the delivery instructions are", "instructions", "123"},
      {"And the delivery instructions?", "instructions", "123"},
      {"The saved instructions are what?", "instructions", "123"},
      {"Please change the delivery instructions", "delivery", "123"},
      {"The delivery instructions are leave it at reception", "delivery", "123"},
      {"What are the delivery instructions for another order?", "instructions", "unknown"},
      {"No, don't save that", "refuse", "123"}
    ] do
  state = %{
    base
    | caller_history: base.caller_history <> "\n" <> phrase,
      latest_caller_segment: phrase,
      new_caller_text: phrase
  }

  state =
    if intent == "refuse",
      do: %{
        state
        | delivery_drafts: [
            %{order: "123", status: "pending", instructions: "leave it at reception"}
          ]
      },
      else: state

  {:ok, response} =
    TypeSafe.system_one(OrderDesk.TypeSafe,
      state: state,
      questions: Interpretation.questions(state)
    )

  judgment = Interpretation.interpret_answers(response.answers)

  snapshot = %Parlora.ContextSnapshot{
    session_id: "instructions-replay",
    tasks: %{
      "items" => %{
        revision: 1,
        status: :completed,
        input: %{order: "123", operation: "items", user_revision: 1},
        context_wait: %{expired?: true, recheck_key: "3:verify"}
      }
    },
    transcripts: [%{speaker: :user, delta: phrase, arrival_order: 3}],
    pending_delegations: %{"read" => %{status: :pending}}
  }

  {:ok, decisions} =
    AppPolicy.interpret(snapshot, %Parlora.ContextTrigger{}, classify: fn _ -> judgment end)

  IO.puts(
    Jason.encode!(%{
      phrase: phrase,
      judgment: inspect(judgment),
      answers:
        Map.new(response.answers, fn {key, answer} ->
          {key, Map.take(answer, [:choice, :probabilities])}
        end),
      decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
    })
  )

  if target == "unknown" do
    # Missing target must clarify, whether intent is confident or also uncertain.
    unless response.answers["target"].choice == "unknown", do: raise("Borrowed an old order")

    unless match?([%{kind: :request_clarification}], decisions),
      do: raise("An unspecified different order must not dispatch work")
  else
    unless judgment == {:ok, %{intent: intent, order: target}}, do: raise("Unexpected judgment")
  end

  if intent == "instructions" and target == "123" do
    unless match?(
             [%{kind: :start_task, input: %{operation: "instructions", order: "123"}}],
             decisions
           ),
           do: raise("Expected saved-instructions lookup without clarification")
  end
end
