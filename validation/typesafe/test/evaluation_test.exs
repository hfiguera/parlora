defmodule ParloraTypeSafeEvalTest do
  use ExUnit.Case, async: true

  test "held-out labels are never sent and all expected options exist" do
    cases = File.read!("cases.json") |> JSON.decode!()
    assert length(cases) == 30
    assert length(Enum.uniq_by(cases, & &1["id"])) == 30

    for c <- cases do
      refute Map.has_key?(c["state"], "expected")
      questions = ParloraTypeSafeEval.questions(c["state"])

      for {key, expected} <- c["expected"],
          do: assert(Map.has_key?(questions[key].criteria, expected))
    end
  end

  test "high-confidence wrong answers remain errors and use selected probability for gating" do
    answers =
      Map.new(~w(intent relation target confirmation), fn key ->
        {key,
         %{choice: "wrong", confidence: 0.99, probabilities: %{"wrong" => 0.7, "right" => 0.3}}}
      end)

    expected = Map.new(answers, fn {key, _answer} -> {key, "right"} end)
    result = ParloraTypeSafeEval.score(expected, answers)
    refute result.exact
    refute result.passes_probability_gate
    assert Enum.all?(result.matches, fn {_key, matched} -> matched == false end)
  end

  test "summary includes failed requests in deadlines and counts false approvals" do
    row = %{
      outcome: "ok",
      duration_ms: 250,
      exact: false,
      passes_probability_gate: true,
      matches: %{"intent" => true, "relation" => true, "target" => true, "confirmation" => false},
      actual: %{"confirmation" => "approve"},
      expected: %{"confirmation" => "unclear"},
      usage: %{input_tokens: 10, output_tokens: 5}
    }

    result = ParloraTypeSafeEval.summary([row, %{outcome: "timeout", duration_ms: 5_001}])
    assert result.requests == 2
    assert result.successful == 1
    assert result.exact == 0
    assert result.false_approvals == 1
    assert result.over_policy_deadline == 1
    assert result.latency_ms.p95 == 5_001
    assert result.usage.input_tokens == 10
  end
end
