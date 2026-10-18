defmodule OrderDesk.RequestContinuationTest do
  use ExUnit.Case, async: true
  alias OrderDesk.{AppPolicy, Interpretation}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  test "continuation choice is limited to read-only work without an outstanding question" do
    for operation <- ["status", "items", "instructions", "delivery", "refuse", "cancel"],
        reply <- [nil, %{question: "Which order?"}] do
      state = %{
        active_task: %{order: "123", operation: operation},
        recent_work: [],
        order_candidates: ["123"],
        clarification_reply: reply
      }

      offered? =
        Map.has_key?(Interpretation.questions(state)["intent"].criteria, "handled_continuation")

      assert offered? == (operation in ["status", "items", "instructions"] and reply == nil)
    end
  end

  test "continuation without admitted context requires confidence in both intent and order" do
    for field <- ["intent", "target"] do
      answers = %{
        "intent" => %{
          choice: "handled_continuation",
          probabilities: %{"handled_continuation" => 0.99}
        },
        "target" => %{choice: "123", probabilities: %{"123" => 0.99}}
      }

      answers = put_in(answers, [field, :probabilities], %{answers[field].choice => 0.79})

      assert {:error, {:uncertain, %{uncertain_fields: [^field]}}} =
               Interpretation.interpret_answers(answers)
    end
  end

  test "a confident trailing read continuation retains the already admitted order" do
    for operation <- ["status", "items", "instructions"],
        status <- [:running, :completed],
        {act, target_probability} <- [
          {nil, 0.79},
          {%{
             choice: "presence",
             probabilities: %{"presence" => 0.55, "other" => 0.2, "uncertain" => 0.25}
           }, 0.99},
          {%{
             choice: "presence",
             probabilities: %{"presence" => 0.46, "other" => 0.29, "uncertain" => 0.25}
           }, 1.0},
          {%{
             choice: "presence",
             probabilities: %{"presence" => 0.55, "other" => 0.2, "uncertain" => 0.25}
           }, 0.79}
        ] do
      state = %{
        continuation_state()
        | active_task: %{operation: operation, order: "825", status: status},
          handled_caller_input: "Do you know what items are",
          new_caller_text: " there"
      }

      answers =
        continuation_answers()
        |> Map.put("speech_act", act)
        |> put_in(["target", :probabilities], %{"825" => target_probability})

      assert {:ok, %{intent: "handled_continuation", order: "825"}} =
               Interpretation.interpret_answers(answers, state)
    end
  end

  test "retaining an admitted target cannot relax new requests or corrections" do
    state = %{
      continuation_state()
      | active_task: %{operation: "items", order: "825"},
        new_caller_text: " there"
    }

    for intent <- [
          "items",
          "order_status",
          "instructions",
          "lookup_progress",
          "retry_lookup",
          "delivery",
          "cancel",
          "refuse"
        ] do
      answers =
        put_in(continuation_answers(), ["intent"], %{
          choice: intent,
          probabilities: %{intent => 0.99}
        })

      assert {:error, {:uncertain, %{uncertain_fields: fields}}} =
               Interpretation.interpret_answers(answers, state)

      assert "target" in fields
    end

    for guarded <- [
          %{state | active_task: %{operation: "delivery", order: "825"}},
          %{state | clarification_reply: %{question: "Which order?"}},
          %{state | handled_caller_input: ""},
          %{state | handled_caller_input: nil},
          %{state | new_caller_text: ""},
          %{state | new_caller_text: " in order 123"},
          %{state | new_caller_text: " sorry, I mean 123"},
          %{state | new_caller_text: " eight twenty"},
          %{state | new_caller_text: " 82"},
          %{state | new_caller_text: " in another order"},
          %{state | new_caller_text: " in the previous order"},
          %{state | new_caller_text: " not that order"}
        ] do
      assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
               Interpretation.interpret_answers(continuation_answers(), guarded)
    end

    for target <- ["123", "unknown"] do
      answers =
        put_in(continuation_answers(), ["target"], %{
          choice: target,
          probabilities: %{target => 0.79}
        })

      assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
               Interpretation.interpret_answers(answers, state)
    end

    answers =
      put_in(continuation_answers(), ["intent", :probabilities], %{
        "handled_continuation" => 0.79
      })

    assert {:error, {:uncertain, %{uncertain_fields: ["intent", "target"]}}} =
             Interpretation.interpret_answers(answers, state)
  end

  defp continuation_answers do
    %{
      "intent" => %{
        choice: "handled_continuation",
        probabilities: %{"handled_continuation" => 0.99}
      },
      "target" => %{choice: "825", probabilities: %{"825" => 0.79, "unknown" => 0.21}}
    }
  end

  test "observed confidence split between equivalent read actions does not ask again" do
    state = continuation_state()

    for {continuation, items} <- [{0.61, 0.39}, {0.29, 0.71}] do
      answers = split_answers(continuation, items)

      assert {:ok, %{intent: "handled_continuation", order: "124"}} =
               Interpretation.interpret_answers(answers, state)
    end
  end

  test "equivalent-read confidence cannot combine distinct actions or uncertain targets" do
    for state <- [
          %{continuation_state() | active_task: %{operation: "status", order: "124"}},
          %{continuation_state() | active_task: %{operation: "delivery", order: "124"}},
          %{continuation_state() | active_task: %{operation: "items", order: "123"}},
          %{continuation_state() | clarification_reply: %{question: "Which operation?"}},
          %{continuation_state() | new_caller_text: " in order 825"},
          %{continuation_state() | new_caller_text: " in another order"}
        ] do
      assert {:error, {:uncertain, _}} =
               Interpretation.interpret_answers(split_answers(0.61, 0.39), state)
    end

    answers = put_in(split_answers(0.61, 0.39), ["target", :probabilities], %{"124" => 0.79})

    assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
             Interpretation.interpret_answers(answers, continuation_state())

    for alternative <- ["retry_lookup", "delivery", "cancel", "refuse", "instructions", "unclear"] do
      answers =
        put_in(split_answers(0.61, 0.39), ["intent", :probabilities], %{
          "handled_continuation" => 0.61,
          alternative => 0.39
        })

      assert {:error, {:uncertain, _}} =
               Interpretation.interpret_answers(answers, continuation_state())
    end
  end

  defp continuation_state do
    %{
      active_task: %{operation: "items", order: "124"},
      clarification_reply: nil,
      handled_caller_input: " What items are in that",
      new_caller_text: " order"
    }
  end

  defp split_answers(continuation, items) do
    %{
      "intent" => %{
        choice: if(continuation > items, do: "handled_continuation", else: "items"),
        probabilities: %{"handled_continuation" => continuation, "items" => items}
      },
      "target" => %{choice: "124", probabilities: %{"124" => 1.0}}
    }
  end

  test "continuation judgment cannot silently discard a changed target or modify a draft" do
    for {text, operation, order} <- [
          {" there", "items", "124"},
          {" in order 124", "items", "123"},
          {" in another order", "items", "123"},
          {" there", "delivery", "123"},
          {" there", "refuse", "123"}
        ] do
      task = %{
        revision: 1,
        status: :completed,
        input: %{
          order: "123",
          operation: operation,
          user_revision: 1,
          request_text: "What items are"
        },
        context_wait: %{expired?: true, recheck_key: "3:verify"}
      }

      snapshot = %ContextSnapshot{
        session_id: "continuation-guard",
        tasks: %{"active" => task},
        transcripts: [%{speaker: :user, delta: text, arrival_order: 3}]
      }

      assert {:ok, [%{kind: :request_clarification}]} =
               AppPolicy.interpret(snapshot, %ContextTrigger{},
                 classify: fn _ -> {:ok, %{intent: "handled_continuation", order: order}} end
               )
    end
  end
end
