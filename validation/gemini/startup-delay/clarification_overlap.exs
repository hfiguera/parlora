# Offline diagnostic, run in the standalone OrderDesk consumer. The semantic
# judgment is fixed, not a claim about the uncaptured live TypeSafe response.
alias Parlora.{ContextSnapshot, ContextTrigger}

snapshot = %ContextSnapshot{
  session_id: "offline-clarification-overlap",
  revision: 6,
  application_context: %{voice_provider: :gemini},
  transcripts: [
    %{
      speaker: :assistant,
      delta: "Sure. What would you like the new instructions to be?",
      arrival_order: 6,
      timing: :unavailable
    },
    %{
      speaker: :user,
      delta: "Right, let's change the delivery instructions.",
      arrival_order: 5,
      timing: :unavailable
    },
    %{speaker: :assistant, delta: "Order 124 contains one desk lamp.", arrival_order: 3},
    %{speaker: :user, delta: "What items are in order 124?", arrival_order: 1}
  ],
  tasks: %{
    "items" => %{
      revision: 1,
      status: :completed,
      input: %{order: "124", operation: "items", instructions: nil, user_revision: 1},
      context_wait: %{expired?: true, recheck_key: "5:verify"}
    }
  }
}

{:ok, decisions} =
  OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{},
    classify: fn _ -> {:ok, %{intent: "delivery", order: "124"}} end
  )

[%{kind: :wait_for_context, recheck_after_ms: nil}] = decisions

IO.puts(
  Jason.encode!(%{
    assistant_already_asked: hd(snapshot.transcripts).delta,
    application_requests_competing_clarification: false,
    action: :wait_for_caller,
    scope: "Fixed-judgment regression reproduction, not live interpreter evidence"
  })
)
