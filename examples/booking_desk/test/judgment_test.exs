defmodule BookingDesk.JudgmentTest do
  use ExUnit.Case, async: false
  alias BookingDesk.Judgment

  defp answer(value, p \\ 0.99), do: %{choice: value, probabilities: %{value => p}}

  test "uncertain results are cached for unchanged input but not new caller or backend state" do
    state = %{
      latest_user: "The morning one",
      verified_offers: [],
      interpretation_binding: %{
        session_id: "cache-#{System.unique_integer([:positive])}",
        provider_generation: 0,
        caller_cursor: 10
      }
    }

    owner = self()

    evaluate = fn _ ->
      send(owner, :evaluated)
      {:error, :uncertain}
    end

    for _ <- 1..20 do
      assert Judgment.classify(state, evaluator: evaluate) == {:error, :uncertain}
    end

    assert_receive :evaluated
    refute_receive :evaluated, 20

    for changed <- [
          %{state | latest_user: "Ten fifteen"},
          %{state | verified_offers: [%{time: "10:15"}]},
          put_in(state.interpretation_binding.provider_generation, 1),
          put_in(state.interpretation_binding.caller_cursor, 11),
          put_in(state.interpretation_binding.session_id, "other-call")
        ] do
      assert Judgment.classify(changed, evaluator: evaluate) == {:error, :uncertain}
      assert_receive :evaluated
    end
  end

  test "partial fields can clarify but neither uncertain time nor consent can authorize a write" do
    answers = %{
      "intent" => answer("choose_slot"),
      "date" => answer("2026-11-05"),
      "clinician" => answer("lee"),
      "time" => answer("10:15", 0.84)
    }

    assert {:incomplete, %{"time" => "unknown", "clinician" => "lee"}, ["time"]} =
             Judgment.decode(answers)

    answers = put_in(answers["time"], answer("10:15"))
    assert {:ok, %{"time" => "10:15"}} = Judgment.decode(answers)

    assert {:error, :uncertain} =
             Judgment.decode(put_in(answers["intent"], answer("confirm", 0.84)))

    assert {:incomplete, _, ["time"]} =
             Judgment.decode(
               answers
               |> Map.put("intent", answer("confirm"))
               |> Map.put("time", answer("unknown"))
             )

    assert {:error, :uncertain} = Judgment.decode(%{})
  end

  test "period selections require a unique current offered time and preserve doctor ambiguity" do
    answers = %{
      "intent" => answer("choose_slot"),
      "date" => answer("2026-11-05"),
      "clinician" => answer("lee"),
      "time" => answer("morning")
    }

    morning = %{date: "2026-11-05", time: "10:15", clinician: "lee"}
    afternoon = %{morning | time: "14:00"}
    state = %{verified_offers: [morning, afternoon]}
    assert {:ok, %{"time" => "10:15"}} = Judgment.decode(answers, state)

    assert {:ok, %{"time" => "14:00"}} =
             Judgment.decode(Map.put(answers, "time", answer("afternoon")), state)

    assert {:incomplete, _, ["time"]} = Judgment.decode(answers, %{verified_offers: []})

    assert {:incomplete, _, ["time"]} =
             Judgment.decode(answers, %{verified_offers: [morning, %{morning | time: "11:00"}]})

    assert {:incomplete, _, ["time"]} =
             Judgment.decode(answers, %{verified_offers: [%{morning | date: "2026-11-04"}]})

    assert {:incomplete, _, ["time"]} =
             Judgment.decode(Map.put(answers, "time", answer("morning", 0.84)), state)

    # Same time with different doctors resolves only the time, never a doctor.
    assert {:ok, %{"time" => "10:15", "clinician" => "unknown"}} =
             Judgment.decode(
               Map.put(answers, "clinician", answer("unknown")),
               %{verified_offers: [morning, %{morning | clinician: "patel"}]}
             )
  end
end
