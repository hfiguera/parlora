defmodule OrderDesk.HumanCallRecoveryTest do
  use ExUnit.Case, async: true
  alias OrderDesk.{AppPolicy, CallerHistory, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  defp snapshot(text) do
    %ContextSnapshot{
      session_id: "human-call-regression",
      transcripts: [
        %{speaker: :user, delta: text, arrival_order: 5, timing: :unavailable},
        %{
          speaker: :assistant,
          delta: "Order 124 is out for delivery.",
          arrival_order: 2,
          timing: :unavailable
        },
        %{speaker: :user, delta: "Check order 124.", arrival_order: 1, timing: :unavailable}
      ],
      tasks: %{
        "read" => %{
          revision: 1,
          status: :completed,
          input: %{order: "124", operation: "status", instructions: nil, user_revision: 1}
        }
      },
      pending_delegations: %{"new-call" => %{status: :pending}}
    }
  end

  defp decide(snapshot, classify) do
    AppPolicy.interpret(snapshot, %ContextTrigger{}, classify: classify)
  end

  test "explicit read corrections survive uncertain classification and untimed history" do
    for text <- [
          "No, 123",
          "Sorry, 123",
          "Oh, sorry. Order one two three.",
          "The order number is 123.",
          "Actually, I meant order one hundred twenty three."
        ] do
      assert {:ok,
              [
                %{
                  kind: :supersede_task,
                  input: %{order: "123", operation: "status"},
                  delegation_id: "new-call"
                }
              ]} =
               decide(snapshot(text), fn _ ->
                 flunk("Explicit read correction need not be classified")
               end)
    end

    same = "Great. Oh, sorry, I make a mistake. I mean order 124."

    assert {:ok, [%{kind: :associate_delegation}]} =
             decide(snapshot(same), fn _ ->
               flunk("Equivalent correction must not create another job")
             end)
  end

  test "partial, conflicting, and actionable text is never a number-only correction" do
    for text <- [
          "No, 12",
          "No, 123, 124",
          "No, 123 cancel it",
          "Actually leave it at reception",
          "No, one two",
          "The order number is 123 or 124",
          "No, don't save 123",
          "Sorry, 12",
          "Sorry, one hundred twenty",
          "Sorry, 123, 124",
          "Sorry, 123 cancel it",
          "Sorry, don't save 123"
        ] do
      assert Speech.read_correction(text) == nil, text
    end
  end

  test "a clarification about the earlier correction retains its read operation" do
    s =
      put_in(snapshot("No, 123").tasks["read"][:clarification], %{
        context_revision: 3,
        message: "Do you mean order 124?",
        input: %{
          known_operation: nil,
          known_order: "124",
          missing: ["operation"],
          request_text: "Great. Oh, sorry, I make a mistake. I mean order 124."
        }
      })

    assert {:ok,
            [
              %{
                kind: :supersede_task,
                input: %{operation: "status", order: "123"},
                delegation_id: "new-call"
              }
            ]} =
             decide(s, fn _ -> flunk("Do not forget the operation of the corrected read") end)
  end

  test "a pending write cannot borrow the completed read operation" do
    s =
      put_in(snapshot("No, 123").tasks["read"][:clarification], %{
        context_revision: 3,
        message: "Which order should the draft target?",
        input: %{known_operation: "delivery", known_order: "124", missing: ["instructions"]}
      })

    assert {:ok, [%{kind: :wait_for_context}]} =
             decide(s, fn state ->
               assert state.clarification_reply.number_reply == "123"
               {:ok, %{intent: "delivery", order: "123"}}
             end)
  end

  test "unknown new operation remains unknown after an explicit number correction" do
    s =
      put_in(snapshot("No, 123").tasks["read"][:clarification], %{
        context_revision: 3,
        message: "What would you like to do?",
        input: %{
          known_operation: nil,
          known_order: "124",
          missing: ["operation"],
          request_text: "Do something with that order"
        }
      })

    assert {:ok, [%{kind: :wait_for_context}]} =
             decide(s, fn _ -> flunk("Retain partial clarification") end)
  end

  test "latest untimed speaker run preserves fragments without merging previous exchanges" do
    s = snapshot("No, 1")

    fragments = [
      %{speaker: :user, delta: "23", arrival_order: 6, timing: :unavailable} | s.transcripts
    ]

    assert CallerHistory.latest(fragments) == "No, 123"
    assert CallerHistory.text(fragments) == "Check order 124.No, 123"

    assert {:ok, [%{kind: :supersede_task, input: %{order: "123"}, delegation_id: "new-call"}]} =
             decide(%{s | transcripts: fragments}, fn _ -> flunk("Split correction") end)

    assert {:ok, _} =
             decide(snapshot("What items are in that order?"), fn state ->
               assert state.latest_caller_segment == "What items are in that order?"
               assert state.handled_caller_input == "Check order 124."
               {:ok, %{intent: "items", order: "124"}}
             end)
  end

  test "timed overlapping backchannels do not split the latest caller segment" do
    fragments = [
      %{speaker: :user, delta: " four", start_ms: 150, end_ms: 300},
      %{speaker: :assistant, delta: "Mm-hmm", start_ms: 90, end_ms: 200},
      %{speaker: :user, delta: "Check order one two", start_ms: 0, end_ms: 150}
    ]

    assert CallerHistory.latest(fragments) == "Check order one two four"
  end

  test "reported Live-with transcript creates a literal draft after settling, never a save" do
    s = snapshot("Let's to change that. Put there Live with My Neighbor.")
    classify = fn _ -> {:ok, %{intent: "delivery", order: "124"}} end
    assert {:ok, [%{kind: :wait_for_context, recheck_key: "5:delivery"}]} = decide(s, classify)
    s = put_in(s.tasks["read"][:context_wait], %{expired?: true, recheck_key: "5:delivery"})

    assert {:ok,
            [
              %{
                kind: :start_task,
                input: %{operation: "delivery", instructions: "Live with My Neighbor"}
              }
            ]} = decide(s, classify)

    assert Speech.delivery("live with my") == nil
    assert Speech.delivery("live music please") == nil
  end

  test "missing wording clarification targets the pending tool without denying other drafts" do
    s =
      put_in(snapshot("Let's change that").tasks["read"][:context_wait], %{
        expired?: true,
        recheck_key: "5:verify"
      })

    assert {:ok,
            [
              %{
                kind: :request_clarification,
                task_id: "read",
                delegation_id: "new-call",
                message: message
              }
            ]} =
             decide(s, fn _ -> {:ok, %{intent: "delivery", order: "124"}} end)

    assert message =~ "new edit request is missing its delivery wording"
    assert message =~ "does not create a draft"
  end

  test "unfinished phone destination cannot become a draft, but its completion can" do
    text = "Okay, let's change the delivery instructions. Put there left in my front"
    classify = fn _ -> {:ok, %{intent: "delivery", order: "124"}} end
    assert Speech.delivery(text) == nil

    s =
      put_in(snapshot(text).tasks["read"][:context_wait], %{
        expired?: true,
        recheck_key: "5:verify"
      })

    assert {:ok, [%{kind: :request_clarification, message: message}]} = decide(s, classify)
    assert message =~ "new edit request is missing its delivery wording"

    complete =
      put_in(snapshot(text <> " door").tasks["read"][:context_wait], %{
        expired?: true,
        recheck_key: "5:delivery"
      })

    assert {:ok, [%{kind: :start_task, input: %{instructions: "left in my front door"}}]} =
             decide(complete, classify)

    assert Speech.delivery("Leave it at the front") == "Leave it at the front"
    assert Speech.delivery("Leave it in my front garden") == "Leave it in my front garden"
    assert Speech.numbers("123123") == []
    assert Speech.numbers("1123") == []
  end
end
