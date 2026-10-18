unless System.get_env("ORDER_DESK_TYPESAFE") == "1",
  do: raise("Set ORDER_DESK_TYPESAFE=1 for this bounded live classifier check")

base = %{
  caller_history: "Check order 124\nWhat items are in that order?",
  active_task: %{order: "124", operation: "items", status: :completed},
  handled_caller_input: "What items are in that order?",
  delivery_drafts: [],
  recent_work: [
    %{order: "124", operation: "items", status: :completed},
    %{order: "124", operation: "status", status: :completed}
  ],
  order_candidates: ["124"]
}

rows =
  for {text, expected} <- [
        {"Any delivery instructions?", "instructions"},
        {"Okay, let's to change the delivery instructions and say left in the front desk",
         "delivery"},
        {"Let me check", "none"},
        {"Okay, thank you. Bye", "none"},
        {"I confirm it", "none"},
        {"Are you already saved in the web page", "instructions"},
        {"Thanks, but check order 124", "status"},
        {"Actually, leave it with the neighbor", "delivery"}
      ] do
    state =
      Map.merge(base, %{
        caller_history: base.caller_history <> "\n" <> text,
        latest_caller_segment: text,
        new_caller_text: text
      })

    result = OrderDesk.Interpretation.classify(state, fresh?: true)
    passed = match?({:ok, %{intent: ^expected}}, result)
    %{text: text, expected: expected, passed: passed, result: inspect(result)}
  end

IO.puts(Jason.encode!(rows, pretty: true))
if Enum.any?(rows, &(not &1.passed)), do: System.halt(1)
