alias OrderDesk.{AppPolicy, Clarification, Interpretation}
alias Parlora.{ContextSnapshot, ContextTrigger}

make = fn reply, input, question ->
  %ContextSnapshot{
    session_id: "streaming-fix",
    pending_delegations: %{
      "owner" => %{
        status: :pending,
        received_at_us: 10,
        clarification: %{context_revision: 3, input: input, message: question},
        context_wait: %{recheck_key: "5:verify", expired?: true}
      },
      "new" => %{status: :pending, received_at_us: 20}
    },
    transcripts: [
      %{speaker: :user, delta: reply, arrival_order: 5},
      %{speaker: :assistant, delta: question, arrival_order: 4},
      %{
        speaker: :user,
        delta: input[:request_text] || "Do you know what items ordered",
        arrival_order: 3
      }
    ]
  }
end

initial = Clarification.number_input(%{entry: %{}}, "Check order one two")

items = %{
  known_order: "124",
  known_operation: nil,
  candidate_operation: "items",
  missing: ["operation"],
  request_text: "Do you know what items ordered"
}

cases = [
  {"initial_suffix", "three", initial, "Please finish saying the three-digit order number.",
   "status", "123"},
  {"initial_repeated_full_number", "One hundred twenty four, one two four", initial,
   "Please finish saying the three-digit order number.", "status", "124"},
  {"confirm_items", "Yes", items, Clarification.question(items), "items", "124"},
  {"correct_confirmation", "No, the delivery status", items, Clarification.question(items),
   "status", "124"},
  {"reject_confirmation", "No", items, Clarification.question(items), "none", "unknown"}
]

results =
  for round <- 1..2, {name, reply, input, question, intent, order} <- cases do
    {:ok, decisions} =
      AppPolicy.interpret(
        make.(reply, input, question),
        %ContextTrigger{kind: :delegation, delegation_id: "new"},
        classify: fn state ->
          {:ok, response} =
            TypeSafe.system_one(OrderDesk.TypeSafe,
              state: state,
              questions: Interpretation.questions(state)
            )

          judgment = Interpretation.interpret_answers(response.answers)
          send(self(), {:evidence, state, response.answers, judgment})
          judgment
        end
      )

    receive do
      {:evidence, state, answers, judgment} ->
        passed =
          if intent == "none",
            do: Enum.all?(decisions, &(&1.kind in [:request_clarification, :wait_for_context])),
            else:
              Enum.any?(decisions, fn d ->
                d.kind == :start_task and d.delegation_id == "owner" and
                  d.input[:operation] == intent and d.input[:order] == order
              end)

        row = %{
          round: round,
          name: name,
          passed: passed,
          state: state,
          judgment: inspect(judgment),
          decisions:
            Enum.map(decisions, &Map.take(&1, [:kind, :input, :message, :delegation_id])),
          answers:
            Map.new(answers, fn {key, answer} ->
              {key, Map.take(answer, [:choice, :probabilities])}
            end)
        }

        IO.puts(Jason.encode!(row))
        row
    after
      1000 -> raise "Classifier unexpectedly bypassed"
    end
  end

File.write!(Path.join(__DIR__, "fix-results.json"), Jason.encode!(results, pretty: true) <> "\n")
if Enum.any?(results, &(!&1.passed)), do: raise("Verification failed; evidence retained")
