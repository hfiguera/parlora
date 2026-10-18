history =
  "Sure, check the order one hundred twenty three\nActually, I mean one hundred twenty four\nDo you know what items are in that order\nAnd do you know what are the delivery instructions\nOkay, let's change that. Put there, leave on front in the small box"

base = %{
  caller_history: history,
  latest_caller_segment: "",
  active_task: %{order: "124", operation: "delivery", status: :completed},
  new_caller_text: "",
  handled_caller_input: "Okay, let's change that. Put there, leave on front in the small box",
  delivery_drafts: [
    %{order: "124", status: "applied", instructions: "leave on front in the small box"}
  ],
  recent_work: [
    %{order: "124", operation: "delivery", status: :completed},
    %{order: "124", operation: "items", status: :completed},
    %{order: "124", operation: "status", status: :completed}
  ],
  order_candidates: ["123", "124"]
}

expected = %{
  "exact_applied" => "none",
  "explicit_applied" => "none",
  "exact_pending" => "none",
  "other_ack" => "none",
  "question_applied" => "instructions",
  "tentative_question" => "instructions",
  "direct_question" => "instructions",
  "ack_new_request" => "status",
  "ack_refusal" => "refuse",
  "ack_correction" => "delivery"
}

rows =
  for {label, phrase, draft_status} <- [
        {"exact_applied", "I think I did", "applied"},
        {"explicit_applied", "I clicked Confirm on the page", "applied"},
        {"question_applied", "Was it saved on the page?", "applied"},
        {"exact_pending", "I think I did", "pending"},
        {"ack_new_request", "I did, now check order 123", "applied"},
        {"tentative_question", "I think I did, can you check?", "applied"},
        {"direct_question", "Did I save it?", "pending"},
        {"ack_refusal", "I did, but don't save that", "pending"},
        {"ack_correction", "Done, actually leave it with the neighbor", "applied"},
        {"other_ack", "I already confirmed it", "applied"}
      ] do
    state = %{
      base
      | caller_history: history <> "\n" <> phrase,
        latest_caller_segment: phrase,
        new_caller_text: phrase,
        delivery_drafts: [%{hd(base.delivery_drafts) | status: draft_status}]
    }

    case TypeSafe.system_one(OrderDesk.TypeSafe,
           state: state,
           questions: OrderDesk.Interpretation.questions(state)
         ) do
      {:ok, response} ->
        judgment = OrderDesk.Interpretation.interpret_answers(response.answers)

        task = %{
          revision: 1,
          status: :completed,
          input: %{
            order: "124",
            operation: "delivery",
            instructions: "leave on front in the small box",
            user_revision: 1
          },
          context_wait: %{expired?: true, recheck_key: "3:verify"}
        }

        snapshot = %Parlora.ContextSnapshot{
          session_id: "diagnostic",
          tasks: %{"active" => task},
          transcripts: [
            %{speaker: :user, delta: phrase, arrival_order: 3},
            %{
              speaker: :assistant,
              delta: "To actually change anything, look at the page and confirm it",
              arrival_order: 2
            },
            %{speaker: :user, delta: base.handled_caller_input, arrival_order: 1}
          ],
          pending_delegations:
            if(expected[label] == "none", do: %{}, else: %{"followup" => %{status: :pending}})
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
  intent = expected[row.variant]

  unless row[:judgment] && String.starts_with?(row.judgment, "{:ok,") &&
           String.contains?(row.judgment, "intent: \"#{intent}\""),
         do: raise("Unexpected classification for #{row.variant}")

  if intent == "none" and row.decisions != [], do: raise("Acknowledgment created work")

  if intent == "instructions" and not Enum.any?(row.decisions, &(&1.kind == :start_task)),
    do: raise("Verification did not dispatch a read")
end
