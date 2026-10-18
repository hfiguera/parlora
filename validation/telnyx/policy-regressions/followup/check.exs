unless System.get_env("ORDER_DESK_TYPESAFE") == "1",
  do: raise("Set ORDER_DESK_TYPESAFE=1 for the bounded classifier replay")

base = %{
  caller_history:
    " Yes, check the order one hundred twenty three, please\n Actually I, I, sorry, I mean one hundred twenty four\n Do you know what it is order",
  latest_caller_segment: " Do you know what it is order",
  active_task: %{order: "124", operation: "status", status: :completed},
  new_caller_text: " Do you know what it is order",
  handled_caller_input: " Actually I, I, sorry, I mean one hundred twenty four",
  delivery_drafts: [],
  recent_work: [%{order: "124", operation: "status", status: :completed}],
  order_candidates: ["123", "124"]
}

variants = [
  {"ambiguous_followup", base},
  {"operation_reply_without_number",
   %{
     base
     | caller_history: base.caller_history <> "\n The item's list",
       latest_caller_segment: " The item's list",
       new_caller_text: base.new_caller_text <> "\n The item's list"
   }},
  {"different_missing_order",
   %{
     base
     | caller_history: base.caller_history <> "\n Check another order",
       latest_caller_segment: " Check another order",
       new_caller_text: " Check another order"
   }},
  {"number_reply",
   %{
     base
     | caller_history: base.caller_history <> "\n One hundred twenty four",
       latest_caller_segment: " One hundred twenty four",
       new_caller_text: base.new_caller_text <> "\n One hundred twenty four"
   }},
  {"explicit_items_reply",
   %{
     base
     | caller_history: base.caller_history <> "\n One hundred twenty four\n The item's list",
       latest_caller_segment: " The item's list",
       new_caller_text: base.new_caller_text <> "\n One hundred twenty four\n The item's list"
   }},
  {"clear_items_followup",
   %{
     base
     | caller_history: "Check order 124\nWhat items are in that order?",
       latest_caller_segment: "What items are in that order?",
       new_caller_text: "What items are in that order?"
   }}
]

rows =
  for {label, state} <- variants do
    case TypeSafe.system_one(OrderDesk.TypeSafe,
           state: state,
           questions: OrderDesk.Interpretation.questions(state)
         ) do
      {:ok, response} ->
        judgment = OrderDesk.Interpretation.interpret_answers(response.answers)

        task = %{
          revision: 2,
          status: :completed,
          input: %{order: "124", operation: "status", user_revision: 1},
          context_wait: %{expired?: true, recheck_key: "3:verify"}
        }

        snapshot = %Parlora.ContextSnapshot{
          session_id: "diagnostic",
          tasks: %{"active" => task},
          transcripts: [
            %{speaker: :user, delta: state.latest_caller_segment, arrival_order: 3},
            %{speaker: :assistant, delta: "It is out for delivery", arrival_order: 2},
            %{speaker: :user, delta: "Check order 124", arrival_order: 1}
          ],
          pending_delegations: %{"followup" => %{status: :pending}}
        }

        {:ok, decisions} =
          OrderDesk.AppPolicy.interpret(snapshot, %Parlora.ContextTrigger{},
            classify: fn _ -> judgment end
          )

        %{
          variant: label,
          answers:
            Map.new(response.answers, fn {k, a} -> {k, Map.take(a, [:choice, :probabilities])} end),
          judgment: inspect(judgment),
          decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
        }

      {:error, error} ->
        %{variant: label, error_kind: error.kind}
    end
  end

IO.puts(Jason.encode!(rows, pretty: true))

for row <- rows do
  case row do
    %{variant: name, decisions: [%{kind: :request_clarification, message: message}]}
    when name in ["ambiguous_followup", "number_reply"] ->
      unless String.contains?(message, "For order 124") and
               not String.contains?(message, "three-digit"), do: raise("Wrong clarification")

    %{
      variant: "different_missing_order",
      decisions: [%{kind: :request_clarification, message: message}]
    } ->
      unless String.contains?(message, "three-digit"), do: raise("Borrowed a missing order")

    %{
      variant: name,
      decisions: [%{kind: :start_task, input: %{order: "124", operation: "items"}}]
    }
    when name in [
           "operation_reply_without_number",
           "explicit_items_reply",
           "clear_items_followup"
         ] ->
      :ok

    _ ->
      raise("Classifier replay did not match the expected decision")
  end
end
