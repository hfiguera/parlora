defmodule BookingDesk.JudgmentTest do
  use ExUnit.Case, async: false
  alias BookingDesk.Judgment

  defp answer(value, p \\ 0.99), do: %{choice: value, probabilities: %{value => p}}

  test "approved speech spellings become canonical doctors only after the confidence gate" do
    fields = %{"intent" => answer("availability"), "date" => answer("2026-11-04")}

    for spelling <- ["li", "lee"] do
      assert {:ok, %{"clinician" => "lee"}} =
               Judgment.decode(Map.put(fields, "clinician", answer(spelling)))
    end

    for spelling <- ["li", "lee", "patel", "any"] do
      assert {:ok, %{"clinician" => "unknown"}} =
               Judgment.decode(Map.put(fields, "clinician", answer(spelling, 0.84)))
    end

    for spelling <- ["unknown", "lin", "smith", "leigh"] do
      assert {:ok, %{"clinician" => "unknown"}} =
               Judgment.decode(Map.put(fields, "clinician", answer(spelling)))
    end

    assert {:ok, %{"clinician" => "any"}} =
             Judgment.decode(Map.put(fields, "clinician", answer("any")))

    assert {:incomplete, %{"clinician" => "lee", "intent" => "unknown"}, ["intent"]} =
             fields
             |> Map.put("clinician", answer("li"))
             |> Map.put("intent", answer("confirm", 0.84))
             |> Judgment.decode()

    choices = BookingDesk.Clinicians.choices()
    assert choices["lee"] =~ "Dr. Li"
    refute Map.has_key?(choices, "li")
    assert BookingDesk.Store.clinicians() == %{"lee" => "Dr. Lee", "patel" => "Dr. Patel"}
    assert BookingDesk.Clinicians.guidance() =~ "explicit spelling correction"
  end

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

    assert {:incomplete, %{"intent" => "unknown", "date" => "2026-11-05"}, ["intent"]} =
             Judgment.decode(put_in(answers["intent"], answer("confirm", 0.84)))

    assert {:incomplete, _, ["time"]} =
             Judgment.decode(
               answers
               |> Map.put("intent", answer("confirm"))
               |> Map.put("time", answer("unknown"))
             )

    assert {:error, :uncertain} = Judgment.decode(%{})
  end

  test "uncertain intent preserves independently confident preferences without granting an action" do
    fields = %{
      "date" => answer("2026-11-05"),
      "clinician" => answer("lee"),
      "time" => answer("10:15")
    }

    for intent <- [answer("replace_search", 0.84), answer("confirm", 0.84), answer("unclear")] do
      assert {:incomplete, judgment, ["intent"]} =
               Judgment.decode(Map.put(fields, "intent", intent))

      assert judgment == %{
               "intent" => "unknown",
               "date" => "2026-11-05",
               "clinician" => "lee",
               "time" => "10:15"
             }
    end

    assert {:incomplete, %{"clinician" => "unknown", "time" => "unknown"}, ["intent"]} =
             fields
             |> Map.put("clinician", answer("patel", 0.84))
             |> Map.put("time", answer("14:00", 0.84))
             |> Map.put("intent", answer("replace_search", 0.84))
             |> Judgment.decode()
  end

  test "a period without verified offers cannot invent a slot" do
    answers = %{
      "intent" => answer("choose_slot"),
      "date" => answer("2026-11-05"),
      "clinician" => answer("lee"),
      "time" => answer("morning")
    }

    assert {:incomplete, %{"time" => "unknown"}, ["time"]} =
             Judgment.decode(answers, %{verified_offers: []})
  end

  test "cancellation approves its immutable proposal without inventing replacement slot fields" do
    answers = %{
      "intent" => answer("confirm"),
      "date" => answer("unknown"),
      "time" => answer("unknown"),
      "clinician" => answer("unknown")
    }

    assert {:ok, %{"intent" => "confirm"}} =
             Judgment.decode(answers, %{proposal: %{change: "cancel"}})

    for change <- ~w(book reschedule) do
      assert {:incomplete, _, ["date", "time", "clinician"]} =
               Judgment.decode(answers, %{proposal: %{change: change}})
    end
  end

  test "a failed interpreter returns unavailable and a fresh input can recover" do
    state = %{latest_user: "failure-#{System.unique_integer([:positive])}"}

    assert {:error, :unavailable} =
             Judgment.classify(state, evaluator: fn _ -> raise "service failed" end)

    assert {:ok, %{"intent" => "none"}} =
             Judgment.classify(%{state | latest_user: state.latest_user <> " corrected"},
               evaluator: fn _ -> {:ok, %{"intent" => "none"}} end
             )
  end

  test "confidence gates reject malformed probabilities instead of treating them as permission" do
    for probability <- [nil, "0.99", true, -1, 1.1] do
      refute Judgment.confident?(%{choice: "confirm", probabilities: %{"confirm" => probability}})
    end

    refute Judgment.confident?(%{choice: "confirm", probabilities: nil})
    assert Judgment.confident?(answer("confirm"))
  end
end
