defmodule BookingDesk.RecoveryTest do
  use ExUnit.Case, async: true
  alias BookingDesk.{Consent, Recovery, Reply}

  test "exact questions and simple replies avoid model calls" do
    opts = [clarification_judge: fn _ -> raise "unnecessary model call" end]

    assert {:ok, :accept} =
             Reply.answer("Check that date?", "Check that date?", "Yes, please!", %{}, opts)

    assert {:ok, :decline} =
             Reply.answer("Check that date?", "Check that date?", "No thanks", %{}, opts)
  end

  test "paraphrases and richer replies use a bounded semantic decision" do
    scope = %{task_id: "current", generation: 0, cursor: 20}

    opts = [
      clarification_judge: fn state ->
        assert state.expected_question == "Should I check that date?"
        assert state.spoken_question == "Want me to look at that day's options?"
        assert state.latest_user == "Absolutely, that would help"
        assert state.interpretation_binding == scope
        {:ok, :accept}
      end
    ]

    assert {:ok, :accept} =
             Reply.answer(
               "Should I check that date?",
               "Want me to look at that day's options?",
               "Absolutely, that would help",
               scope,
               opts
             )

    for result <- [{:error, :unavailable}, {:error, :uncertain}, {:ok, :unknown}] do
      assert {:error, :uncertain} =
               Reply.answer("Expected?", "Another question?", "Yes", scope,
                 clarification_judge: fn _ -> result end
               )
    end
  end

  test "oversized semantic input is rejected without starting another request" do
    assert {:error, :uncertain} =
             Reply.answer("Expected?", "Other?", String.duplicate("a", 6_001), %{},
               clarification_judge: fn _ -> raise "must not call" end
             )
  end

  test "semantic confidence cannot override an explicit condition or question" do
    for text <- ["Yes, if it is covered", "Yes?", "Yes, but wait", "Don't do that"] do
      assert {:ok, :other} =
               Reply.answer("Expected?", "A paraphrase?", text, %{},
                 clarification_judge: fn _ -> {:ok, :accept} end
               )
    end
  end

  test "consent veto covers questions, conditions, refusals and trailing corrections" do
    for text <- [
          "Yes?",
          "Yes, but wait",
          "I cannot confirm",
          "Yes, if it is covered",
          "No",
          "That's incorrect",
          "Please stop",
          "Yes, except Wednesday",
          "I don't want that"
        ] do
      refute Consent.unconditional?(text)
    end

    for text <- ["Yes, please", "Please book it", "That's correct", "Go ahead"] do
      assert Consent.unconditional?(text)
    end
  end

  test "recovery commands are explicit and do not match negated fragments" do
    assert {:ok, %{"intent" => "restart"}} = Recovery.command("Can we start over?")
    assert {:ok, %{"intent" => "repeat"}} = Recovery.command("Say that again")
    assert {:ok, %{"intent" => "retry"}} = Recovery.command("Please try again")
    assert Recovery.command("Don't start over") == nil
    assert Recovery.command("Yes, if we start over") == nil
  end

  test "pending writes remain protected while terminal results permit a new request" do
    for operation <- ~w(confirm reminder_confirm) do
      for status <- [:submitted, :queued, :uncertain] do
        assert Recovery.pending_write?(%{input: %{operation: operation}, status: status})
      end

      for status <- [:completed, :failed, :cancelled] do
        refute Recovery.pending_write?(%{input: %{operation: operation}, status: status})
      end
    end

    refute Recovery.pending_write?(nil)
  end
end
