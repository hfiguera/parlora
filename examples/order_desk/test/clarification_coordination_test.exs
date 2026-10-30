defmodule OrderDesk.ClarificationCoordinationTest do
  use ExUnit.Case, async: true
  alias Parlora.{ContextSnapshot, ContextTrigger}

  defp context do
    %ContextSnapshot{
      application_context: %{voice_provider: :gemini},
      transcripts: [
        %{speaker: :assistant, delta: " new instructions to be?", arrival_order: 7},
        %{speaker: :assistant, delta: "What would you like the", arrival_order: 6},
        %{speaker: :user, delta: "Let's change the delivery instructions.", arrival_order: 5}
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
  end

  defp interpret(snapshot),
    do:
      OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: fn _ -> {:ok, %{intent: "delivery", order: "124"}} end
      )

  test "a pending save defers only clarification and its lease expires without a worker update" do
    snapshot = context()
    # Reproduce the caller's follow-up during a pending save rather than an
    # already captioned assistant question.
    snapshot = %{
      snapshot
      | transcripts: Enum.filter(snapshot.transcripts, &(&1.speaker == :user))
    }

    hold = System.monotonic_time(:millisecond) + 500
    snapshot = put_in(snapshot.application_context[:save_announcement_until_ms], hold)

    assert {:ok, [%{kind: :wait_for_context, recheck_key: key, recheck_after_ms: delay}]} =
             interpret(snapshot)

    assert key == "save-announcement:#{hold}"
    assert delay in 1..500

    expired =
      put_in(
        snapshot.application_context[:save_announcement_until_ms],
        System.monotonic_time(:millisecond) - 1
      )

    assert {:ok, [%{kind: :request_clarification}]} = interpret(expired)

    decision = %Parlora.ContextDecision{
      kind: :supersede_task,
      task_id: "items",
      expected_task_revision: 1,
      input: %{order: "123"}
    }

    assert {:ok, [^decision]} = OrderDesk.Clarification.coordinate({:ok, [decision]}, snapshot)
  end

  test "Phonic respects pending saves and avoids competing with a captioned clarification" do
    snapshot = %{context() | application_context: %{voice_provider: :phonic}}
    assert {:ok, [%{kind: :wait_for_context}]} = interpret(snapshot)

    hold = System.monotonic_time(:millisecond) + 500

    snapshot = %{
      snapshot
      | transcripts: Enum.filter(snapshot.transcripts, &(&1.speaker == :user)),
        application_context: %{voice_provider: :phonic, save_announcement_until_ms: hold}
    }

    assert {:ok, [%{kind: :wait_for_context, recheck_key: key}]} = interpret(snapshot)
    assert key == "save-announcement:#{hold}"
  end

  test "already captioned Gemini question suppresses competing application question" do
    assert {:ok, [%{kind: :wait_for_context, recheck_after_ms: nil}]} = interpret(context())
  end

  test "captioned requests without a question mark also prevent competing clarification" do
    for text <- [
          "I need a three-digit order number to look this up for you.",
          "I'm sorry, that order number is too long. I need a three-digit order number to look up your status.",
          "Please provide a three-digit order number to check your status.",
          "Please review the wording on the page and press Confirm to save it."
        ] do
      snapshot = %{
        context()
        | transcripts: [
            %{speaker: :assistant, delta: text, arrival_order: 7}
            | Enum.drop(context().transcripts, 2)
          ]
      }

      assert {:ok, [%{kind: :wait_for_context, recheck_after_ms: nil}]} = interpret(snapshot)

      assert {:ok, [%{kind: :request_clarification}]} =
               interpret(%{snapshot | application_context: %{}})

      reply = %{speaker: :user, delta: "Yes", arrival_order: 8}
      decision = %Parlora.ContextDecision{kind: :request_clarification, message: "What wording?"}

      assert {:ok, [^decision]} =
               OrderDesk.Clarification.coordinate({:ok, [decision]}, %{
                 snapshot
                 | transcripts: [reply | snapshot.transcripts]
               })
    end
  end

  test "ordinary facts and an earlier request do not suppress a new clarification" do
    for text <- [
          "Order 124 has no delivery instructions.",
          "I need to look up your order number.",
          "Please provide your order number. Your order has shipped.",
          "The instructions say please provide a three-digit order number."
        ] do
      snapshot = %{
        context()
        | transcripts: [
            %{speaker: :assistant, delta: text, arrival_order: 7}
            | Enum.drop(context().transcripts, 2)
          ]
      }

      assert {:ok, [%{kind: :request_clarification}]} = interpret(snapshot)
    end
  end

  test "new caller input is evaluated and does not authorize a draft with missing wording" do
    snapshot = context()

    snapshot = %{
      snapshot
      | transcripts: [%{speaker: :user, delta: "Yes", arrival_order: 8} | snapshot.transcripts]
    }

    assert {:ok, decisions} = interpret(snapshot)
    refute Enum.any?(decisions, &(&1.kind in [:start_task, :supersede_task]))
    assert Enum.all?(decisions, &(&1.kind in [:wait_for_context, :request_clarification]))
  end

  test "a declarative caption does not suppress clarification, and OpenAI retains its behavior" do
    snapshot = context()

    assert {:ok, [%{kind: :request_clarification}]} =
             interpret(%{snapshot | application_context: %{}})

    [head | rest] = snapshot.transcripts

    assert {:ok, [%{kind: :request_clarification}]} =
             interpret(%{snapshot | transcripts: [%{head | delta: " new instructions."} | rest]})
  end

  test "an unconfirmed submission is not supplied to interpretation as an asked question" do
    marker = %{message: "Save it?", delivery: :unconfirmed, input: %{known_operation: nil}}
    reply = OrderDesk.Clarification.reply(marker, "Yes", nil)
    assert reply.question == nil
    assert reply.submitted_question == "Save it?"
    assert reply.delivery == :unconfirmed
    assert reply.previous_operation == nil
  end
end
