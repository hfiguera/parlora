# Constructed snapshots from visible wording; original classifier scores unavailable.
if Application.fetch_env!(:order_desk, :database) != ":memory:", do: raise("Use memory DB")
alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.{ContextSnapshot, ContextTrigger}

defmodule RetryReplay do
  def snapshot(variant) do
    base = [
      {:user, "Sure, please check the order 123"},
      {:assistant, "It’s shipped and expected Friday."},
      {:user, "Sorry, a- make a mistake. The order number is 134"},
      {:assistant, "I'm not seeing that order number for your account."},
      {:user, "Are you sure"},
      {:assistant,
       "Yeah, that's what I'm getting here. If you like, I can try again or check a different order."},
      {:user, "Just try again"}
    ]

    task = %{
      revision: 2,
      status: :completed,
      input: %{
        order: "134",
        operation: "status",
        instructions: nil,
        user_revision: 3,
        request_text: "Sorry, a- make a mistake. The order number is 134"
      }
    }

    proposal = %{
      known_order: "134",
      known_operation: nil,
      candidate_operation: "status",
      missing: ["operation"],
      request_text: "Are you sure\nJust try again"
    }

    marker = %{
      context_revision: 7,
      message: "Do you mean the delivery status for order 134?",
      input: proposal
    }

    {fragments, task} =
      case variant do
        :retry ->
          {base, task}

        :correct_candidate ->
          {base ++ [{:assistant, marker.message}, {:user, "One hundred twenty four"}],
           Map.put(task, :clarification, marker)}

        :correct_known ->
          marker =
            put_in(marker.input, %{proposal | known_operation: "status", missing: ["order"]})

          {base ++ [{:assistant, marker.message}, {:user, "One hundred twenty four"}],
           Map.put(task, :clarification, marker)}

        :explicit_status ->
          marker = %{
            marker
            | context_revision: 9,
              message: "Do you mean the delivery status for order 124?",
              input: %{proposal | known_order: "124"}
          }

          {base ++
             [
               {:assistant, "Do you mean the delivery status for order 134?"},
               {:user, "One hundred twenty four"},
               {:assistant, marker.message},
               {:user, "Yes, what is the de-delivery status"}
             ], Map.put(task, :clarification, marker)}

        :status_tail ->
          prefix = "Yes, what is the de-delivery"

          fragments =
            base ++
              [
                {:assistant, "Do you mean the delivery status for order 134?"},
                {:user, "One hundred twenty four"},
                {:assistant, "Do you mean the delivery status for order 124?"},
                {:user, prefix},
                {:assistant, "Order one twenty four is out for delivery."},
                {:user, " status"}
              ]

          {fragments,
           %{
             task
             | revision: 3,
               input: %{task.input | order: "124", user_revision: 11, request_text: prefix}
           }}
      end

    transcripts =
      fragments
      |> Enum.with_index(1)
      |> Enum.map(fn {{speaker, delta}, i} ->
        %{
          speaker: speaker,
          delta: delta,
          arrival_order: i,
          start_ms: i * 1000,
          end_ms: i * 1000 + 500
        }
      end)
      |> Enum.reverse()

    rev = hd(transcripts).arrival_order
    task = Map.put(task, :context_wait, %{expired?: true, recheck_key: "#{rev}:verify"})

    %ContextSnapshot{
      session_id: "constructed-#{variant}",
      revision: rev,
      transcripts: transcripts,
      tasks: %{"lookup" => task},
      pending_delegations: %{"new" => %{status: :pending, received_at_us: 1}},
      application_context: %{actor: "replay"}
    }
  end
end

owner = self()
# Concrete bypass: even a classifier ready to resolve status/124 is not consulted.
{:ok, [number_question]} =
  AppPolicy.interpret(RetryReplay.snapshot(:correct_candidate), %ContextTrigger{},
    classify: fn _ ->
      send(owner, :unexpected_classify)
      {:ok, %{intent: "status", order: "124"}}
    end
  )

true = number_question.kind == :request_clarification
true = number_question.message == "Do you mean the delivery status for order 124?"

receive do
  :unexpected_classify -> raise "Expected number-reply shortcut"
after
  0 -> :ok
end

# Concrete missing retry semantics: confident status for the same order just associates.
{:ok, retry_decisions} =
  AppPolicy.interpret(RetryReplay.snapshot(:retry), %ContextTrigger{},
    classify: fn _ -> {:ok, %{intent: "status", order: "134"}} end
  )

true = Enum.map(retry_decisions, & &1.kind) == [:associate_delegation]

rows =
  for round <- 1..2, variant <- [:retry, :correct_known, :explicit_status, :status_tail] do
    snapshot = RetryReplay.snapshot(variant)

    {:ok, decisions} =
      AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: fn input ->
          {:ok, response} =
            TypeSafe.system_one(OrderDesk.TypeSafe,
              state: input,
              questions: Interpretation.questions(input)
            )

          answers =
            Map.new(response.answers, fn {k, v} -> {k, Map.take(v, [:choice, :probabilities])} end)

          result = Interpretation.interpret_answers(answers)
          send(owner, {:judgment, input, answers, result})
          result
        end
      )

    receive do
      {:judgment, input, answers, result} ->
        row = %{
          round: round,
          variant: variant,
          input: input,
          answers: answers,
          judgment: inspect(result),
          decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
        }

        IO.inspect(Map.take(row, [:round, :variant, :judgment, :decisions]), limit: :infinity)
        row
    after
      1000 -> raise "Missing classification"
    end
  end

File.write!(
  Path.join(__DIR__, "policy-results.json"),
  Jason.encode!(
    %{
      provenance: "Constructed snapshots, not original wire timing or classifier answers.",
      number_shortcut_question: number_question.message,
      retry_decisions: Enum.map(retry_decisions, & &1.kind),
      rows: rows
    }, pretty: true) <> "\n"
)
