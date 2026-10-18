alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.{ContextSnapshot, ContextTrigger}

make = fn reply, input ->
  %ContextSnapshot{
    session_id: "clarification-fix-validation",
    tasks: %{
      "task" => %{
        revision: 2,
        status: :completed,
        input: %{order: "124", operation: "status", instructions: nil, user_revision: 1},
        clarification: %{
          context_revision: 3,
          command_id: "question",
          message: OrderDesk.Clarification.question(input),
          input: input
        },
        context_wait: %{recheck_key: "5:verify", expired?: true}
      }
    },
    pending_delegations: %{"reply" => %{status: :pending}},
    transcripts: [
      %{speaker: :user, delta: reply, arrival_order: 5},
      %{speaker: :assistant, delta: "Please clarify.", arrival_order: 4},
      %{speaker: :user, delta: "Do you know what it is, order", arrival_order: 3},
      %{speaker: :assistant, delta: "Order 124 is out for delivery.", arrival_order: 2},
      %{speaker: :user, delta: "Check order 124", arrival_order: 1}
    ]
  }
end

partial = %{known_order: "124", known_operation: nil, missing: ["operation"]}

controls =
  for {reply, order} <- [
        {"One hundred twenty three", "123"},
        {"one hundred twenty four, one two four", "124"}
      ] do
    {:ok, [decision]} =
      AppPolicy.interpret(make.(reply, partial), %ContextTrigger{},
        classify: fn _ -> raise "A number alone must not select an operation" end
      )

    true = decision.kind == :request_clarification
    true = decision.input.known_order == order
    true = decision.input.missing == ["operation"]
    %{reply: reply, decision: Map.take(decision, [:kind, :message, :input]), passed: true}
  end

cases = [
  {"items_after_operation_question", "What items are in that order?",
   %{known_order: "123", known_operation: nil, missing: ["operation"]}, "items", "123"},
  {"repeated_number_after_items_number_question", "one hundred twenty three, one two three",
   %{known_order: nil, known_operation: "items", missing: ["order"]}, "items", "123"},
  {"repeated_number_after_status_number_question", "one hundred twenty three, one two three",
   %{known_order: nil, known_operation: "status", missing: ["order"]}, "status", "123"}
]

live =
  for round <- 1..2, {name, reply, pending, operation, order} <- cases do
    {:ok, decisions} =
      AppPolicy.interpret(make.(reply, pending), %ContextTrigger{},
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
          Enum.any?(decisions, fn decision ->
            decision.kind in [:start_task, :supersede_task] &&
              decision.input[:order] == order && decision.input[:operation] == operation
          end)

        record = %{
          name: name,
          round: round,
          passed: passed,
          state: state,
          answers:
            Map.new(answers, fn {key, answer} ->
              {key, Map.take(answer, [:choice, :probabilities])}
            end),
          judgment: inspect(judgment),
          decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
        }

        IO.puts(Jason.encode!(record))
        record
    end
  end

result = %{controls: controls, live: live, all_passed: Enum.all?(live, & &1.passed)}
File.write!(Path.join(__DIR__, "fix-results.json"), Jason.encode!(result, pretty: true) <> "\n")
if !result.all_passed, do: raise("Live classifier verification failed; evidence preserved")
