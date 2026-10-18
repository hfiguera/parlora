alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.{ContextSnapshot, ContextTrigger}

variants = [
  {"cardinal_reply", " One hundred twenty three", "status", "123", "status"},
  {"digit_reply", " One two three", "status", "123", "status"},
  {"preserve_items", " One two three", "items", "123", "items"},
  {"change_operation", " What items are in order 123?", "status", "123", "items"},
  {"initial_reply", " One two four", nil, "124", "status"},
  {"mixed_continuation", " three", "status", "123", "status"},
  {"different_missing", " Check another order", "status", nil, nil},
  {"conflicting_reply", " Either order 123 or 124, I am not sure", "status", nil, nil}
]

rows =
  for {name, reply, previous_operation, expected_order, expected_operation} <- variants do
    task = %{
      revision: 1,
      status: :completed,
      input: %{order: "120", operation: previous_operation, user_revision: 3},
      clarification: %{context_revision: 7},
      context_wait: %{recheck_key: "9:verify", expired?: true}
    }

    task = if name == "mixed_continuation", do: Map.delete(task, :clarification), else: task

    earlier = [
      %{speaker: :user, delta: "Sorry, I mean 120", arrival_order: 3},
      %{speaker: :assistant, delta: "Say the number again", arrival_order: 2},
      %{speaker: :user, delta: "Please check the order 10024", arrival_order: 1}
    ]

    # Deliberately omit an assistant speech boundary before the reply: the
    # application's clarification revision must isolate it independently.
    tail =
      if name == "mixed_continuation",
        do: [],
        else: [%{speaker: :user, delta: " three", arrival_order: 5}]

    pending = %{
      status: :pending,
      clarification: %{context_revision: 7},
      context_wait: %{recheck_key: "9:verify", expired?: true}
    }

    snapshot = %ContextSnapshot{
      session_id: "number-replay",
      transcripts: [%{speaker: :user, delta: reply, arrival_order: 9}] ++ tail ++ earlier,
      tasks: if(previous_operation, do: %{"task" => task}, else: %{}),
      pending_delegations: %{"reply" => pending}
    }

    {:ok, decisions} =
      AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: fn state ->
          case TypeSafe.system_one(OrderDesk.TypeSafe,
                 state: state,
                 questions: Interpretation.questions(state)
               ) do
            {:ok, response} ->
              judgment = Interpretation.interpret_answers(response.answers)
              send(self(), {:evidence, state, response.answers, judgment})
              judgment

            {:error, error} ->
              raise("Classifier replay failed: #{error.kind}")
          end
        end
      )

    row =
      receive do
        {:evidence, state, answers, judgment} ->
          %{
            variant: name,
            state: state,
            answers:
              Map.new(answers, fn {key, value} ->
                {key, Map.take(value, [:choice, :probabilities])}
              end),
            judgment: inspect(judgment),
            decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
          }
      after
        0 -> raise("Expected complete reply to reach the classifier: #{name}")
      end

    IO.puts(Jason.encode!(row))

    if expected_order do
      unless Enum.any?(decisions, fn decision ->
               decision.kind in [:start_task, :supersede_task] and
                 decision.input[:order] == expected_order and
                 decision.input[:operation] == expected_operation
             end),
             do: raise("Wrong work for #{name}")
    else
      unless Enum.all?(decisions, &(&1.kind == :request_clarification)) and decisions != [],
        do: raise("Ambiguous reply created work: #{name}")
    end

    row
  end

IO.puts("Passed #{length(rows)} live classifier/policy cases")
