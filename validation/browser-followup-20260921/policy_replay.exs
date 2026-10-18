# Run from examples/order_desk with its normal Keychain wrapper and an in-memory DB.
# Eight bounded read-only TypeSafe calls. No GPT-Live session or persisted order change.
alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.ContextTrigger

Code.require_file("policy_fixture.exs", __DIR__)

inputs =
  Map.new([:prefix, :whole_request, :separated_tail, :overlapping_tail], fn variant ->
    {variant, FollowupReplay.input(FollowupReplay.snapshot(variant))}
  end)

true = inputs.separated_tail.new_caller_text == " there"
true = inputs.separated_tail.latest_caller_segment == " there"
true = inputs.overlapping_tail.new_caller_text == " there"
true = inputs.overlapping_tail.latest_caller_segment == "Do you know what items are there"

# Demonstrate the policy consequence of an uncertain tail after successful work.
{:ok, [question]} =
  AppPolicy.interpret(FollowupReplay.snapshot(:separated_tail), %ContextTrigger{},
    classify: fn _ ->
      {:error, {:uncertain, %{intent: "items", order: "123", uncertain_fields: ["intent"]}}}
    end
  )

true = question.kind == :request_clarification

cached =
  if "--cached" in System.argv(),
    do:
      File.read!(Path.join(__DIR__, "policy-results.json"))
      |> Jason.decode!()
      |> Map.fetch!("rows"),
    else: nil

rows =
  for round <- 1..2, variant <- [:prefix, :whole_request, :separated_tail, :overlapping_tail] do
    input = inputs[variant]

    answers =
      if cached do
        row =
          Enum.find(cached, &(&1["round"] == round and &1["variant"] == Atom.to_string(variant)))

        true = input |> Jason.encode!() |> Jason.decode!() == row["input"]

        Map.new(row["answers"], fn {key, a} ->
          {key, %{choice: a["choice"], probabilities: a["probabilities"]}}
        end)
      else
        {:ok, response} =
          TypeSafe.system_one(OrderDesk.TypeSafe,
            state: input,
            questions: Interpretation.questions(input)
          )

        response.answers
      end

    judgment = Interpretation.interpret_answers(answers)

    {:ok, decisions} =
      AppPolicy.interpret(FollowupReplay.snapshot(variant), %ContextTrigger{},
        classify: fn _ -> judgment end
      )

    row = %{
      round: round,
      variant: variant,
      input: input,
      answers:
        Map.new(answers, fn {key, answer} ->
          {key, Map.take(answer, [:choice, :probabilities])}
        end),
      judgment: inspect(judgment),
      decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
    }

    IO.inspect(Map.take(row, [:round, :variant, :judgment, :decisions]), limit: :infinity)
    row
  end

File.write!(
  Path.join(__DIR__, "policy-results.json"),
  Jason.encode!(
    %{
      provenance:
        "Constructed snapshots using visible call wording; timings and task revisions are controls, not an exact call replay.",
      deterministic_question: question.message,
      rows: rows
    },
    pretty: true
  ) <> "\n"
)
