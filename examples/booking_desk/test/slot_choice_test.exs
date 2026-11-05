defmodule BookingDesk.SlotChoiceTest do
  use ExUnit.Case, async: true
  alias BookingDesk.{Judgment, SlotChoice}

  defp answer(choice, probability \\ 0.99),
    do: %{choice: choice, probabilities: %{choice => probability}}

  defp state(text, spoken \\ "Dr. Lee has 10:15 AM, 1 PM or 2:30 PM on November fifth.") do
    %{
      latest_user: text,
      dialogue: [%{speaker: :assistant, text: spoken}, %{speaker: :user, text: text}],
      verified_offers:
        Enum.map(~w(10:15 13:00 14:30), fn time ->
          %{date: "2026-11-05", time: time, clinician: "lee"}
        end)
    }
  end

  defp decode(state, choice, probability \\ 0.99, intent \\ "choose_slot") do
    Judgment.decode(
      %{
        "intent" => answer(intent),
        "date" => answer("unknown"),
        "clinician" => answer("unknown"),
        "time" => answer("unknown"),
        "slot" => answer(choice, probability)
      },
      state
    )
  end

  test "a single slot decision supplies its complete verified tuple without independent field guesses" do
    for {text, choice, time} <- [
          {"The first one", "2026-11-05/lee/10:15", "10:15"},
          {"The first option", "2026-11-05/lee/10:15", "10:15"},
          {"The morning one", "2026-11-05/lee/10:15", "10:15"},
          {"The morning one, please.", "2026-11-05/lee/10:15", "10:15"},
          {"The second option", "2026-11-05/lee/13:00", "13:00"},
          {"The last one", "2026-11-05/lee/14:30", "14:30"},
          {"The later one", "2026-11-05/lee/14:30", "14:30"}
        ] do
      assert {:ok, judgment} = decode(state(text), choice)
      assert judgment["date"] == "2026-11-05"
      assert judgment["clinician"] == "lee"
      assert judgment["time"] == time
      assert judgment["intent"] == "choose_slot"
      assert judgment["offered_slot"]
    end
  end

  test "the evaluator receives spoken ordering and subset, never positional candidate labels" do
    state = state("The first one", "Dr. Lee has 2:30 PM or 1 PM on November fifth.")
    questions = Judgment.questions(state)
    assert Map.has_key?(questions, "slot")
    assert {:ok, wire} = TypeSafe.Question.to_wire(questions)

    assert Map.keys(wire["slot"].criteria) |> Enum.sort() ==
             Enum.sort(Map.keys(SlotChoice.candidates(state)) ++ ["ambiguous", "none"])

    refute Map.has_key?(Judgment.questions(%{verified_offers: []}), "slot")

    # The semantic evaluator selects the spoken first option, not the first inventory entry.
    assert {:ok, %{"time" => "14:30"}} = decode(state, "2026-11-05/lee/14:30")

    assert SlotChoice.candidates(state) ==
             SlotChoice.candidates(%{
               state
               | verified_offers: Enum.reverse(state.verified_offers)
             })
  end

  test "ambiguous, unverified, unavailable or low-confidence selections cannot become proposals" do
    for {text, choice, probability} <- [
          {"The afternoon one", "ambiguous", 0.99},
          {"The first or maybe second", "ambiguous", 0.99},
          {"The morning one if my insurance covers it", "ambiguous", 0.99},
          {"Not the first one", "none", 0.99},
          {"Is the first option available?", "none", 0.99},
          {"The first one", "2026-11-05/lee/10:15", 0.89},
          {"The first one", "unoffered", 0.99}
        ] do
      assert {:incomplete, %{"time" => "unknown"}, ["slot"]} =
               decode(state(text), choice, probability)
    end

    state = state("The first one")

    assert {:incomplete, _, ["slot"]} =
             SlotChoice.resolve(%{"intent" => "choose_slot"}, nil, state)

    assert {:incomplete, _, ["slot"]} =
             decode(%{state | verified_offers: tl(state.verified_offers)}, "2026-11-05/lee/10:15")
  end

  test "ambiguous doctor, date, and multiple morning matches stay unresolved" do
    state = state("The morning one")
    morning = hd(state.verified_offers)

    for extra <- [
          %{morning | clinician: "patel"},
          %{morning | date: "2026-11-06"},
          %{morning | time: "11:00"}
        ] do
      state = %{state | verified_offers: state.verified_offers ++ [extra]}
      assert {:incomplete, _, ["slot"]} = decode(state, "ambiguous")
    end
  end

  test "slot selection preserves rescheduling while date-only changes can still search" do
    state = Map.put(state("The morning one"), :conversation, %{goal: "reschedule"})

    assert {:ok, %{"intent" => "reschedule", "time" => "10:15"}} =
             decode(state, "2026-11-05/lee/10:15")

    assert {:incomplete, _, ["date", "time"]} = decode(state, "none", 0.99, "reschedule")
  end

  test "neither an uncertain intent nor a confirmation can be promoted by a slot answer" do
    state = state("The first one")

    for intent <- ["unclear", "confirm"] do
      refute match?(
               {:ok, %{"offered_slot" => true}},
               decode(state, "2026-11-05/lee/10:15", 0.99, intent)
             )
    end
  end
end
