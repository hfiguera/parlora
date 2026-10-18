Code.require_file("judgment.exs", __DIR__)
ExUnit.start()

defmodule ParloraJevClarificationPilot.Test do
  use ExUnit.Case, async: true
  alias ParloraJevClarificationPilot.Judgment

  defp answer(choice, confidence), do: %{choice: choice, probabilities: %{choice => confidence}}

  test "uncertainty, missing answers and low confidence cannot suppress clarification" do
    for value <- [nil, %{}, answer("covered", 0.84), answer("uncertain", 1.0)] do
      assert Judgment.interpret(value) == {:error, :uncertain}
    end

    assert Judgment.interpret(answer("covered", 0.85)) == {:ok, "covered"}
    assert Judgment.interpret(answer("different", 0.85)) == {:ok, "different"}
  end

  test "v2 requires both current caller request and coverage" do
    coverage = answer("covered", 0.99)
    assert Judgment.interpret_pair(%{"coverage" => coverage}) == {:error, :uncertain}

    assert Judgment.interpret_pair(%{
             "request" => answer("request", 0.84),
             "coverage" => coverage
           }) == {:error, :uncertain}

    assert Judgment.interpret_pair(%{
             "request" => answer("not_request", 0.95),
             "coverage" => coverage
           }) == {:ok, "different"}

    assert Judgment.interpret_pair(%{
             "request" => answer("request", 0.95),
             "coverage" => coverage
           }) == {:ok, "covered"}
  end

  test "prompt variants preserve one-call structured judgments" do
    assert Map.keys(Judgment.questions(:v1)) == ["coverage"]
    assert Map.keys(Judgment.questions(:v2)) |> Enum.sort() == ["coverage", "request"]
    assert Enum.all?(Map.values(Judgment.questions(:v2)), &(&1.type == :choice))
  end
end
