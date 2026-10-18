defmodule OrderDesk.AppPolicyTest do
  use ExUnit.Case, async: true
  alias Parlora.{ContextSnapshot, ContextTrigger}

  defp snapshot(text, active \\ %{}) do
    %ContextSnapshot{
      session_id: "test",
      application_context: %{actor: "test-actor"},
      transcripts: [%{speaker: :user, delta: text, arrival_order: 5}],
      tasks: active,
      pending_delegations: %{"delegation" => %{status: :pending}}
    }
  end

  defp decide(snapshot, intent, order),
    do:
      OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: fn _state -> {:ok, %{intent: intent, order: order}} end
      )

  defp task,
    do: %{
      "task" => %{
        revision: 1,
        input: %{order: "123", operation: "status", instructions: nil, user_revision: 1}
      }
    }

  test "new requests, corrections and different operations map deterministically" do
    assert {:ok, [%{kind: :start_task, input: %{order: "124", actor: "test-actor"}}]} =
             decide(snapshot("Check 124"), "status", "124")

    assert {:ok,
            [
              %{
                kind: :supersede_task,
                task_id: "task",
                expected_task_revision: 1,
                delegation_id: "delegation"
              }
            ]} =
             decide(snapshot("Actually 124", task()), "status", "124")

    assert {:ok, [%{kind: :start_task, input: %{operation: "items"}}]} =
             decide(snapshot("What is in it?", task()), "items", "123")

    assert {:ok, [%{kind: :associate_delegation}]} =
             decide(snapshot("Still checking?", task()), "status", "123")

    assert {:ok, [%{kind: :start_task}]} =
             OrderDesk.AppPolicy.interpret(snapshot("Check 124 too", task()), %ContextTrigger{},
               classify: fn _ -> {:ok, %{intent: "status", order: "124", additional?: true}} end
             )
  end

  test "a follow-up without delegation names only its admission anchor" do
    context = %{snapshot("What is in it?", task()) | pending_delegations: %{}}

    assert {:ok,
            [
              %{
                kind: :start_task,
                anchor_task_id: "task",
                expected_anchor_revision: 1,
                task_id: nil,
                expected_task_revision: nil,
                delegation_id: nil,
                input: %{operation: "items", order: "123"}
              }
            ]} = decide(context, "items", "123")
  end

  test "uncertain, incomplete and failed interpretation waits then clarifies" do
    s = snapshot("Actually order one hundred twenty", task())
    assert {:ok, [%{kind: :wait_for_context}]} = decide(s, "status", "unknown")
    s = put_in(s.tasks["task"][:context_wait], %{expired?: true, recheck_key: "5:settle"})

    assert {:ok, [%{kind: :wait_for_context, recheck_key: "5:verify"}]} =
             decide(s, "status", "unknown")

    s = put_in(s.tasks["task"][:context_wait], %{expired?: true, recheck_key: "5:verify"})
    assert {:ok, [%{kind: :request_clarification}]} = decide(s, "status", "unknown")

    assert {:ok, [%{kind: :request_clarification, message: message}]} =
             OrderDesk.AppPolicy.interpret(s, %ContextTrigger{},
               classify: fn _ -> {:error, :timeout} end
             )

    assert message =~ "unavailable"
  end

  test "delivery uses literal text and never creates an approval command" do
    snapshot = snapshot("For order 124 leave it at reception.")

    assert {:ok, [%{kind: :wait_for_context, recheck_key: "5:delivery"}]} =
             decide(snapshot, "delivery", "124")

    settled =
      put_in(snapshot.pending_delegations["delegation"][:context_wait], %{
        expired?: true,
        recheck_key: "5:delivery"
      })

    assert {:ok, [%{input: %{operation: "delivery", instructions: "leave it at reception"}}]} =
             decide(settled, "delivery", "124")

    assert {:ok, [%{kind: :wait_for_context}]} =
             decide(snapshot("Yes, change it"), "delivery", "124")
  end

  test "delivery drafts preserve paused destinations without truncating or saving" do
    for literal <- [
          "left in the, front box... in my patio",
          "leave it at reception… beside the door",
          "leave it at reception.. by the stairs"
        ] do
      snapshot = snapshot("For order 123, " <> literal <> ". Thanks.")

      settled =
        put_in(snapshot.pending_delegations["delegation"][:context_wait], %{
          expired?: true,
          recheck_key: "5:delivery"
        })

      assert {:ok,
              [%{kind: :start_task, input: %{operation: "delivery", instructions: ^literal}}]} =
               decide(settled, "delivery", "123")
    end

    assert OrderDesk.Speech.delivery("leave it at reception. Check order 124") ==
             "leave it at reception"

    assert OrderDesk.Speech.delivery("leave it in the box... in my") == nil
    assert OrderDesk.Speech.delivery("leave it at " <> String.duplicate("x", 260)) == nil
  end

  test "reported let-with transcription becomes a literal draft only, after settling" do
    phrase = "Okay, let's change that. I want to change to, let with my neighbor"
    snapshot = snapshot(phrase)

    assert {:ok, [%{kind: :wait_for_context, recheck_key: "5:delivery"}]} =
             decide(snapshot, "delivery", "124")

    settled =
      put_in(snapshot.pending_delegations["delegation"][:context_wait], %{
        expired?: true,
        recheck_key: "5:delivery"
      })

    assert {:ok,
            [
              %{
                kind: :start_task,
                input: %{operation: "delivery", instructions: "let with my neighbor"}
              }
            ]} =
             decide(settled, "delivery", "124")

    assert OrderDesk.Speech.delivery("let with my") == nil
    assert OrderDesk.Speech.delivery("let me check the order") == nil
    assert OrderDesk.Speech.delivery("let it be") == nil
  end

  test "three-digit extraction supports numeric and spoken forms" do
    assert OrderDesk.Speech.numbers("one two four") == ["124"]
    assert OrderDesk.Speech.numbers("one hundred twenty three") == ["123"]
    assert OrderDesk.Speech.numbers("eight hundred and twenty five") == ["825"]
    assert OrderDesk.Speech.numbers("1 23") == ["123"]
    assert OrderDesk.Speech.numbers("one hundred twenty") == ["120"]
    assert OrderDesk.Speech.numbers("one two") == []
  end
end
