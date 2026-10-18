unless System.get_env("ORDER_DESK_TYPESAFE") == "1",
  do: raise("Set ORDER_DESK_TYPESAFE=1 for the bounded live classifier check")

base = %{
  caller_history:
    " Yes, please check the order 123\n Actually, I mean 124\n You know what is the... details... is\n No, I mean the item list\n Okay, and what is the status",
  latest_caller_segment: " Okay, and what is the status",
  active_task: %{order: "124", operation: "items", status: :completed},
  new_caller_text: " Okay, and what is the status",
  handled_caller_input: " No, I mean the item list",
  delivery_drafts: [],
  recent_work: [
    %{order: "124", operation: "items", status: :completed},
    %{order: "124", operation: "status", status: :completed}
  ],
  order_candidates: ["123", "124"]
}

variants =
  [
    {"status_after_items", base, "status", "124"},
    {"current_order_only", %{base | order_candidates: ["124"]}, "status", "124"},
    {"without_prior_status", %{base | recent_work: [base.active_task]}, "status", "124"}
  ] ++
    for {text, expected, order} <- [
          {"What is the delivery status of order 124?", "status", "124"},
          {"Are you still checking?", "followup", "124"},
          {"Have you finished the lookup?", "followup", "124"},
          {"What is the status of your lookup?", "followup", "124"},
          {"What is the status of another order?", "status", "unknown"}
        ] do
      history = base.caller_history |> String.split("\n") |> Enum.drop(-1) |> Enum.join("\n")

      state = %{
        base
        | caller_history: history <> "\n" <> text,
          latest_caller_segment: text,
          new_caller_text: text
      }

      {text, state, expected, order}
    end

rows =
  for {label, state, expected, order} <- variants do
    case TypeSafe.system_one(OrderDesk.TypeSafe,
           state: state,
           questions: OrderDesk.Interpretation.questions(state)
         ) do
      {:ok, response} ->
        judgment = OrderDesk.Interpretation.interpret_answers(response.answers)

        %{
          variant: label,
          expected_intent: expected,
          expected_order: order,
          passed:
            match?({:ok, %{intent: ^expected, order: ^order}}, judgment) or
              (order == "unknown" and
                 match?({:error, {:uncertain, %{order: "unknown"}}}, judgment)),
          answers:
            Map.new(response.answers, fn {key, answer} ->
              {key, Map.take(answer, [:choice, :probabilities])}
            end),
          judgment: inspect(judgment)
        }

      error ->
        %{variant: label, passed: false, error: inspect(error)}
    end
  end

IO.puts(Jason.encode!(rows, pretty: true))
if Enum.any?(rows, &(not &1.passed)), do: System.halt(1)
