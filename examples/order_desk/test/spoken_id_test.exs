defmodule OrderDesk.SpokenIdTest do
  use ExUnit.Case, async: true
  alias OrderDesk.{AppPolicy, CallerHistory, Interpretation, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  test "complete grouped IDs preserve all three digits" do
    for {phrase, id} <- [
          {"one-twenty three", "123"},
          {"one twenty-three", "123"},
          {"ONE, TWENTY, FOUR", "124"},
          {"eight twenty five", "825"},
          {"one ninety nine", "199"},
          {"nine ninety nine", "999"},
          {"one ten", "110"},
          {"one nineteen", "119"},
          {"and one twenty three", "123"},
          {"one twenty three and", "123"},
          {"and one two three", "123"},
          {"one hundred and twenty three", "123"},
          {"zero one two", "012"}
        ] do
      assert Speech.numbers("Check order " <> phrase) == [id]
    end
  end

  test "incomplete or malformed groups never become an unrelated three-digit sum" do
    for phrase <- [
          "one-tw",
          "one two",
          "twenty three",
          "eight ninety nine one",
          "one twenty three four",
          "one hundred twenty twenty",
          "one hundred hundred",
          "one twenty three and one twenty four"
        ] do
      assert Speech.numbers(phrase) == []
    end

    assert Speech.numbers("one twenty\nthree") == ["120"]
    assert Speech.numbers("one twenty. Three") == ["120"]
  end

  test "recorded fragments offer 123 to the real constrained target question before admission" do
    fragments = [" Check", " order", " one-tw", "enty", " three"]

    transcripts =
      fragments
      |> Enum.with_index(1)
      |> Enum.map(fn {delta, index} -> %{speaker: :user, delta: delta, arrival_order: index} end)
      |> Enum.reverse()

    assert CallerHistory.text(transcripts) == " Check order one-twenty three"

    snapshot = %ContextSnapshot{
      session_id: "spoken-id",
      transcripts: transcripts,
      pending_delegations: %{"spoken" => %{status: :pending}}
    }

    classify = fn state ->
      assert state.order_candidates == ["123"]
      choices = Interpretation.questions(state)["target"].criteria
      assert Enum.sort(Map.keys(choices)) == ["123", "unknown"]
      {:ok, %{intent: "status", order: "123"}}
    end

    assert {:ok, [%{kind: :start_task, input: %{order: "123", operation: "status"}}]} =
             AppPolicy.interpret(snapshot, %ContextTrigger{}, classify: classify)
  end
end
