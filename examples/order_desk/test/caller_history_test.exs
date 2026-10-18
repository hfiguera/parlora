defmodule OrderDesk.CallerHistoryTest do
  use ExUnit.Case, async: true
  alias OrderDesk.{AppPolicy, CallerHistory, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger}

  defp fragment(speaker, delta, start, stop),
    do: %{speaker: speaker, delta: delta, start_ms: start, end_ms: stop}

  defp snapshot(fragments) do
    transcripts =
      fragments |> Enum.with_index(1) |> Enum.map(fn {f, i} -> Map.put(f, :arrival_order, i) end)

    %ContextSnapshot{
      session_id: "test",
      transcripts: Enum.reverse(transcripts),
      pending_delegations: %{"d" => %{status: :pending}}
    }
  end

  test "dialogue preserves answers and interleaved sentence tails without inventing turns" do
    s =
      snapshot([
        fragment(:user, "Are you checking?", 0, 100),
        fragment(:assistant, "Yes, ", 100, 200),
        fragment(:assistant, "order 124.", 200, 300),
        fragment(:user, "What items are", 400, 500),
        fragment(:assistant, "Mhm", 450, 550),
        fragment(:user, " there", 500, 600)
      ])

    assert CallerHistory.dialogue(s.transcripts) == [
             %{speaker: :user, text: "Are you checking?"},
             %{speaker: :assistant, text: "Yes, order 124."},
             %{speaker: :user, text: "What items are"},
             %{speaker: :assistant, text: "Mhm"},
             %{speaker: :user, text: " there"}
           ]

    assert CallerHistory.text(s.transcripts) =~ "What items are there"
  end

  test "untimed Gemini backchannels do not break a number across caption fragments" do
    fragments = [
      fragment(:user, "Check order 1", nil, nil),
      Map.put(fragment(:assistant, "Mhm", nil, nil), :timing, :unavailable),
      fragment(:user, "24. Actually order 123.", nil, nil)
    ]

    assert fragments |> snapshot() |> Map.fetch!(:transcripts) |> CallerHistory.text() ==
             "Check order 124. Actually order 123."
  end

  test "dialogue context stays bounded and retains the latest speaker runs" do
    fragments =
      for i <- 1..20 do
        fragment(
          if(rem(i, 2) == 0, do: :assistant, else: :user),
          String.duplicate("x", 600) <> "#{i}",
          i,
          i + 1
        )
      end

    dialogue = fragments |> snapshot() |> Map.fetch!(:transcripts) |> CallerHistory.dialogue()
    assert length(dialogue) == 8
    assert Enum.all?(dialogue, &(String.length(&1.text) <= 512))
    assert String.ends_with?(List.last(dialogue).text, "20")
  end

  test "call replay preserves separate answers and keeps 124 after the progress question" do
    s =
      snapshot([
        fragment(:user, "Can you check my order", 0, 1000),
        fragment(:assistant, "What's the number?", 1200, 1800),
        fragment(:user, "One, two, four", 2000, 3000),
        fragment(:assistant, "Could you repeat?", 3200, 3800),
        fragment(:user, "One hundred twenty four", 4000, 5000),
        fragment(:assistant, "Checking it now", 5200, 5800),
        fragment(:user, "Do you check it", 6000, 7000)
      ])

    assert CallerHistory.text(s.transcripts) ==
             "Can you check my order\nOne, two, four\nOne hundred twenty four\nDo you check it"

    assert {:ok, [%{kind: :start_task, input: %{order: "124"}}]} =
             AppPolicy.interpret(s, %ContextTrigger{},
               classify: fn state ->
                 assert state.order_candidates == ["124"]
                 {:ok, %{intent: "status", order: "124"}}
               end
             )
  end

  test "overlapping assistant speech does not split caller words or numeric fragments" do
    s =
      snapshot([
        fragment(:user, "One hun", 0, 200),
        fragment(:assistant, "Mhm", 100, 400),
        fragment(:user, "dred twenty", 200, 400),
        fragment(:user, " four", 400, 600)
      ])

    assert CallerHistory.text(s.transcripts) == "One hundred twenty four"
    assert Speech.numbers(CallerHistory.text(s.transcripts)) == ["124"]
    s = snapshot([fragment(:user, "1", 0, 100), fragment(:user, "24", 100, 200)])
    assert Speech.numbers(CallerHistory.text(s.transcripts)) == ["124"]
  end

  test "number separators support spoken commas but cannot combine separate segments" do
    assert Speech.numbers("One, two, four") == ["124"]
    assert Speech.numbers("one hundred, twenty-four") == ["124"]
    assert Speech.numbers("1, 2, 4") == ["124"]
    assert Speech.numbers("one two\nfour") == []
    assert Speech.numbers("12\n4") == []
  end

  test "punctuation is retained without advancing the meaningful caller revision" do
    s =
      snapshot([
        fragment(:user, "Check order 123", 0, 1000),
        fragment(:user, ".", 1000, 1050),
        fragment(:assistant, "Checking", 1050, 1100),
        fragment(:user, " — \n", 1100, 1150)
      ])

    assert CallerHistory.revision(s.transcripts) == 1
    assert CallerHistory.text(s.transcripts) =~ "Check order 123."
    next = %{speaker: :user, delta: "Actually 124", arrival_order: 5}
    assert CallerHistory.revision([next | s.transcripts]) == 5
    assert CallerHistory.revision([%{next | delta: "3"} | s.transcripts]) == 5
    assert CallerHistory.revision([]) == 0
  end
end
