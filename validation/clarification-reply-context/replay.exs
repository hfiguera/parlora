alias OrderDesk.{AppPolicy, Interpretation, Speech}
alias Parlora.{ContextSnapshot, ContextTrigger}

make = fn reply, question ->
  %ContextSnapshot{
    session_id: "clarification-diagnosis",
    tasks: %{
      "task" => %{
        revision: 2,
        status: :completed,
        input: %{order: "124", operation: "status", instructions: nil, user_revision: 3},
        clarification: %{context_revision: 7, command_id: "question"},
        context_wait: %{recheck_key: "9:verify", expired?: true}
      }
    },
    pending_delegations: %{"reply" => %{status: :pending}},
    transcripts: [
      %{speaker: :user, delta: reply, arrival_order: 9},
      %{speaker: :assistant, delta: question, arrival_order: 8},
      %{speaker: :user, delta: "Do you know what it is, order", arrival_order: 5},
      %{speaker: :assistant, delta: "Order 124 is out for delivery.", arrival_order: 4},
      %{
        speaker: :user,
        delta: "Sorry, I made a mistake. The order number is one hundred twenty four",
        arrival_order: 3
      },
      %{speaker: :assistant, delta: "Sure, I'll check that order now.", arrival_order: 2},
      %{
        speaker: :user,
        delta: "Hi, yes, I want to check the order one hundred and twenty three",
        arrival_order: 1
      }
    ]
  }
end

capture = fn snapshot ->
  {:ok, _} =
    AppPolicy.interpret(snapshot, %ContextTrigger{},
      classify: fn state ->
        send(self(), {:input, state})
        {:ok, %{intent: "unclear", order: "124"}}
      end
    )

  receive do: ({:input, state} -> state)
end

number_question = "Can you tell me the three-digit order number again?"
operation_question = "Can you tell me what about the order you want checked?"
a = capture.(make.("One hundred twenty three", number_question))
b = capture.(make.("One hundred twenty three", operation_question))
true = a == b

IO.puts(
  Jason.encode!(%{
    check: "different_questions_identical_classifier_input",
    identical: a == b,
    state: a
  })
)

for text <- [
      "One hundred twenty three",
      "one hundred twenty four",
      "one two four",
      "one hundred twenty four, one two four",
      "one hundred twenty four\none two four"
    ] do
  IO.puts(
    Jason.encode!(%{
      check: "number_parser",
      text: text,
      numbers: Speech.numbers(text),
      incomplete: Speech.incomplete_number?(text)
    })
  )
end

# Deterministic demonstration: target uncertainty with a clearly extracted
# different order can still produce a request for the number.
snapshot = make.("One hundred twenty three", operation_question)

{:ok, decisions} =
  AppPolicy.interpret(snapshot, %ContextTrigger{},
    classify: fn _ ->
      {:error,
       {:uncertain, %{intent: "unclear", order: "123", uncertain_fields: ["intent", "target"]}}}
    end
  )

IO.puts(
  Jason.encode!(%{
    check: "known_literal_number_reasked",
    decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message]))
  })
)

if System.get_env("ORDER_DESK_TYPESAFE") == "1" do
  variants = [
    {"bare_123_after_operation_question", make.("One hundred twenty three", operation_question)},
    {"repeated_124_after_number_question",
     make.("one hundred twenty four, one two four", number_question)},
    {"single_124_after_number_question", make.("one two four", number_question)},
    {"explicit_items_control", make.("What items are in order 124?", operation_question)}
  ]

  for round <- 1..2, {name, snapshot} <- variants do
    {:ok, decisions} =
      AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: fn state ->
          {:ok, response} =
            TypeSafe.system_one(OrderDesk.TypeSafe,
              state: state,
              questions: Interpretation.questions(state)
            )

          judgment = Interpretation.interpret_answers(response.answers)
          send(self(), {:classification, state, response.answers, judgment})
          judgment
        end
      )

    receive do
      {:classification, state, answers, judgment} ->
        IO.puts(
          Jason.encode!(%{
            variant: name,
            round: round,
            state: state,
            answers:
              Map.new(answers, fn {key, answer} ->
                {key, Map.take(answer, [:choice, :probabilities])}
              end),
            judgment: inspect(judgment),
            decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
          })
        )
    end
  end
end
