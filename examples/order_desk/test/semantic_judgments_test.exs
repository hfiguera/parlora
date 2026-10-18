defmodule OrderDesk.SemanticJudgmentsTest do
  use ExUnit.Case, async: true
  alias OrderDesk.{AppPolicy, Interpretation}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  defp choice(label, confidence \\ 0.99),
    do: %{choice: label, probabilities: %{label => confidence}}

  defp state do
    %{
      active_task: %{operation: "status", order: "123"},
      recent_work: [],
      order_candidates: ["123", "124"],
      clarification_reply: nil,
      delivery_continuation_eligible: false,
      new_caller_text: "Check 124 too, keep checking 123"
    }
  end

  defp snapshot(text, pending? \\ true) do
    %ContextSnapshot{
      session_id: "semantic-#{Parlora.ID.new()}",
      revision: 5,
      transcripts: [%{speaker: :user, delta: text, arrival_order: 5}],
      tasks: %{
        "old" => %{
          revision: 1,
          status: :running,
          input: %{operation: "status", order: "123", user_revision: 1},
          context_wait: %{expired?: true, recheck_key: "5:verify"}
        }
      },
      pending_delegations: if(pending?, do: %{"d" => %{status: :pending}}, else: %{})
    }
  end

  defp decode(relationship, confidence \\ 0.99) do
    Interpretation.interpret_answers(
      %{
        "intent" => choice("order_status"),
        "target" => choice("124"),
        "relationship" => choice(relationship, confidence)
      },
      state()
    )
  end

  test "presence confidence is independent of order confidence and never executes work" do
    answers = %{
      "speech_act" => choice("presence"),
      "intent" => choice("none", 0.4),
      "target" => choice("unknown", 0.1)
    }

    assert {:ok, %{intent: "presence"}} =
             judgment = Interpretation.interpret_answers(answers, state())

    assert {:ok, []} =
             AppPolicy.interpret(snapshot("Can you hear me?", false), %ContextTrigger{},
               classify: fn _ -> judgment end
             )

    answers = Map.put(answers, "speech_act", choice("presence", 0.79))

    assert {:error, {:uncertain, %{uncertain_fields: ["speech_act"]}}} =
             Interpretation.interpret_answers(answers, state())
  end

  test "uncertain presence cannot veto confident reads, progress or retry judgments" do
    for {intent, operation} <- [
          {"order_status", "status"},
          {"items", "items"},
          {"instructions", "instructions"},
          {"lookup_progress", "followup"},
          {"retry_lookup", "retry_lookup"}
        ] do
      assert {:ok, %{intent: ^operation, order: "123"}} =
               Interpretation.interpret_answers(
                 %{
                   "speech_act" => choice("presence", 0.55),
                   "intent" => choice(intent),
                   "target" => choice("123")
                 },
                 state()
               )
    end
  end

  test "uncertain presence preserves admission of new reads and explicit order corrections" do
    for {text, intent, order, kind, tasks} <- [
          {"Check order 124", "order_status", "124", :start_task, %{}},
          {"What items are in that order?", "items", "123", :start_task, snapshot("").tasks},
          {"What instructions are saved for order 124?", "instructions", "124", :start_task,
           snapshot("").tasks},
          {"Actually, check the delivery status of order 825 instead", "order_status", "825",
           :supersede_task, snapshot("").tasks}
        ] do
      context = %{snapshot(text) | tasks: tasks}

      assert {:ok, [%{kind: ^kind, input: %{order: ^order}}]} =
               AppPolicy.interpret(context, %ContextTrigger{},
                 classify: fn state ->
                   Interpretation.interpret_answers(
                     %{
                       "speech_act" => choice("presence", 0.55),
                       "intent" => choice(intent),
                       "target" => choice(order),
                       "relationship" => choice("replacement")
                     },
                     state
                   )
                 end
               )
    end
  end

  test "uncertain presence cannot lower intent, target or relationship gates" do
    for field <- ["intent", "target", "relationship"] do
      answers = %{
        "speech_act" => choice("presence", 0.55),
        "intent" => choice("order_status"),
        "target" => choice("124"),
        "relationship" => choice("replacement")
      }

      answers = Map.put(answers, field, choice(answers[field].choice, 0.79))
      assert {:error, {:uncertain, _}} = Interpretation.interpret_answers(answers, state())
    end

    assert {:error, {:uncertain, _}} =
             Interpretation.interpret_answers(
               %{
                 "speech_act" => choice("presence", 0.55),
                 "intent" => choice("items"),
                 "target" => choice("unknown")
               },
               state()
             )
  end

  test "uncertain special acts cannot authorize writes, refusals, cancellation or acknowledgments" do
    for intent <- ["delivery", "refuse", "cancel", "none", "unclear"],
        act <- ["presence", "delivery_restatement", "relationship_reply"] do
      assert {:error, {:uncertain, _}} =
               Interpretation.interpret_answers(
                 %{
                   "speech_act" => choice(act, 0.55),
                   "intent" => choice(intent),
                   "target" => choice("123"),
                   "relationship" => choice("replacement")
                 },
                 state()
               )
    end
  end

  test "confident presence during clarification waits without answering the business question" do
    context =
      put_in(snapshot("Can you hear me?").tasks["old"][:clarification], %{
        context_revision: 3,
        message: "Which order's items?",
        input: %{known_order: nil, known_operation: "items", missing: ["order"]}
      })

    assert {:ok, decisions} =
             AppPolicy.interpret(context, %ContextTrigger{},
               classify: fn state ->
                 Interpretation.interpret_answers(
                   %{
                     "speech_act" => choice("presence", 0.8),
                     "intent" => choice("none", 0.4),
                     "target" => choice("unknown", 0.1)
                   },
                   state
                 )
               end
             )

    assert decisions != []
    assert Enum.all?(decisions, &(&1.kind == :wait_for_context))
  end

  test "a missing or uncertain relationship cannot replace or add a lookup" do
    for answer <- [
          nil,
          choice("uncertain"),
          choice("additional", 0.79),
          choice("replacement", 0.79)
        ] do
      judgment =
        Interpretation.interpret_answers(
          %{
            "intent" => choice("order_status"),
            "target" => choice("124"),
            "relationship" => answer
          },
          state()
        )

      assert {:error, {:uncertain, %{uncertain_fields: ["relationship"]}}} = judgment

      assert {:ok, [question]} =
               AppPolicy.interpret(snapshot("Check 124 too"), %ContextTrigger{},
                 classify: fn _ -> judgment end
               )

      assert question.kind == :request_clarification
      assert question.input.missing == ["relationship"]
      assert question.input.known_order == "124"
      assert question.input.known_operation == "status"
      assert question.message =~ "in addition to the previous request, or instead"
    end
  end

  test "atomic restatement judgment releases existing work without pooling intent probabilities" do
    input = %{
      state()
      | active_task: %{operation: "delivery", order: "123"},
        delivery_continuation_eligible: true
    }

    answers = %{
      "speech_act" => choice("delivery_restatement"),
      "intent" => %{choice: "delivery", probabilities: %{"delivery" => 0.58, "unclear" => 0.42}},
      "target" => choice("123")
    }

    assert {:ok, %{intent: "delivery_continuation", order: "123"}} =
             Interpretation.interpret_answers(answers, input)

    assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
             Interpretation.interpret_answers(
               Map.put(answers, "target", choice("123", 0.79)),
               input
             )

    assert {:error, {:uncertain, %{uncertain_fields: ["speech_act"]}}} =
             Interpretation.interpret_answers(answers, %{
               input
               | delivery_continuation_eligible: false
             })

    assert {:error, {:uncertain, %{uncertain_fields: ["speech_act"]}}} =
             Interpretation.interpret_answers(
               Map.put(answers, "speech_act", choice("delivery_restatement", 0.79)),
               input
             )
  end

  test "a broad non-special speech act does not add an irrelevant confidence gate" do
    for act <- [choice("uncertain"), choice("other", 0.79)] do
      assert {:ok, %{intent: "status", order: "123"}} =
               Interpretation.interpret_answers(
                 %{
                   "speech_act" => act,
                   "intent" => choice("order_status"),
                   "target" => choice("123")
                 },
                 state()
               )
    end
  end

  test "semantic addition retains the old lookup with and without provider delegation" do
    assert {:ok, %{additional?: true}} = judgment = decode("additional")

    assert {:ok,
            [%{kind: :start_task, delegation_id: "d", input: %{order: "124", additional?: true}}]} =
             AppPolicy.interpret(snapshot("Check 124 too, keep checking 123"), %ContextTrigger{},
               classify: fn _ -> judgment end
             )

    assert {:ok,
            [
              %{
                kind: :start_task,
                anchor_task_id: "old",
                input: %{order: "124", additional?: true}
              }
            ]} =
             AppPolicy.interpret(
               snapshot("Keep checking 123 and check 124 too", false),
               %ContextTrigger{},
               classify: fn _ -> judgment end
             )
  end

  test "another in a correction does not force an additional task" do
    assert {:ok, %{additional?: false}} = judgment = decode("replacement")

    assert {:ok,
            [%{kind: :supersede_task, task_id: "old", input: %{order: "124", additional?: false}}]} =
             AppPolicy.interpret(snapshot("Sorry, I meant another order, 124"), %ContextTrigger{},
               classify: fn _ -> judgment end
             )
  end

  test "irrelevant relationship uncertainty does not block a new operation or current target" do
    for {intent, order} <- [
          {"items", "124"},
          {"order_status", "123"},
          {"presence", "unknown"},
          {"none", "unknown"}
        ] do
      assert {:ok, _} =
               Interpretation.interpret_answers(
                 %{
                   "intent" => choice(intent),
                   "target" => choice(order),
                   "relationship" => choice("uncertain")
                 },
                 state()
               )
    end
  end

  test "relationship clarification retains its target when the caller answers keep both" do
    s = snapshot("Keep both", false)

    s =
      put_in(s.tasks["old"][:clarification], %{
        context_revision: 3,
        input: %{known_order: "124", known_operation: "status", missing: ["relationship"]}
      })

    assert {:ok,
            [
              %{
                kind: :start_task,
                anchor_task_id: "old",
                input: %{order: "124", additional?: true}
              }
            ]} =
             AppPolicy.interpret(s, %ContextTrigger{},
               classify: fn input ->
                 assert input.clarification_reply.pending_request.known_order == "124"
                 assert input.clarification_reply.pending_request.missing == ["relationship"]

                 Interpretation.interpret_answers(
                   %{
                     "speech_act" => choice("relationship_reply"),
                     "intent" => choice("order_status", 0.55),
                     "target" => choice("124"),
                     "relationship" => choice("additional")
                   },
                   input
                 )
               end
             )
  end

  test "relationship reply cannot borrow retained fields for a different target or without a question" do
    pending = %{known_order: "124", known_operation: "status", missing: ["relationship"]}
    input = %{state() | clarification_reply: %{pending_request: pending}}

    answers = %{
      "speech_act" => choice("relationship_reply"),
      "intent" => choice("order_status", 0.55),
      "target" => choice("123"),
      "relationship" => choice("additional")
    }

    assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
             Interpretation.interpret_answers(answers, input)

    assert {:error, {:uncertain, %{uncertain_fields: ["speech_act", "target"]}}} =
             Interpretation.interpret_answers(answers, state())
  end

  test "delivery continuation is offered only when lifecycle and literal guards permit it" do
    base = %{state() | active_task: %{operation: "delivery", order: "123"}}

    refute Map.has_key?(
             Interpretation.questions(base)["speech_act"].criteria,
             "delivery_restatement"
           )

    assert Map.has_key?(
             Interpretation.questions(%{base | delivery_continuation_eligible: true})[
               "speech_act"
             ].criteria,
             "delivery_restatement"
           )

    s = snapshot("Actually, leave at reception")

    s =
      put_in(s.tasks["old"][:input], %{
        order: "123",
        operation: "delivery",
        user_revision: 1,
        request_text: "Leave with my neighbor",
        instructions: "Leave with my neighbor"
      })

    assert {:ok, [%{kind: :request_clarification}]} =
             AppPolicy.interpret(s, %ContextTrigger{},
               classify: fn input ->
                 refute input.delivery_continuation_eligible
                 # Even an incorrect continuation judgment cannot discard a new literal.
                 {:ok, %{intent: "delivery_continuation", order: "123"}}
               end
             )
  end
end
