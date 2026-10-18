# Constructed semantic states from visible captions, not recovered wire fragments.
# Read-only TypeSafe judgments; no voice session or persisted database mutations.
if Application.fetch_env!(:order_desk, :database) != ":memory:", do: raise("Use an in-memory DB")
alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.{ContextSnapshot, ContextTrigger}

make_snapshot = fn variant ->
  initial = [
    {:user, "Yes, please check the order 123"},
    {:assistant, "I'll check order one two three now. Thanks for waiting. It-"},
    {:user, "Sorry, I mean 124"},
    {:assistant, "Sure, I'll switch to order one two four."}
  ]

  progress = [
    {:user, "Do you check it"},
    {:assistant,
     "Yes, I did. Order one two four is out for delivery. The delivery instructions say leave at my front door."}
  ]

  fragments = initial ++ progress ++ [{:user, "Do you know what items are there"}]

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

  user_revision = if variant == :consumed_progress, do: 5, else: 3
  request_text = "Sorry, I mean 124"

  task = %{
    revision: 2,
    status: :completed,
    input: %{
      order: "124",
      operation: "status",
      instructions: nil,
      user_revision: user_revision,
      request_text: request_text
    },
    context_wait: %{expired?: true, recheck_key: "7:verify"}
  }

  transcripts =
    if variant == :no_progress,
      do: Enum.reject(transcripts, &(&1.arrival_order in [5, 6])),
      else: transcripts

  %ContextSnapshot{
    session_id: "constructed-#{variant}",
    revision: 7,
    transcripts: transcripts,
    tasks: %{"status" => task},
    pending_delegations: %{"items" => %{status: :pending, received_at_us: 1}},
    application_context: %{actor: "replay"}
  }
end

ablation? = "--ablation" in System.argv()

output =
  Path.join(__DIR__, if(ablation?, do: "fix-ablation-results.json", else: "fix-results.json"))

cached =
  if "--cached" in System.argv(),
    do: output |> File.read!() |> Jason.decode!() |> Map.fetch!("rows"),
    else: nil

variants =
  if ablation?,
    do: [
      :accumulated_without_continuation,
      :consumed_without_continuation,
      :operation_specific_continuation
    ],
    else: [:accumulated_progress, :consumed_progress, :no_progress]

rows =
  for round <- 1..2, variant <- variants do
    base =
      case variant do
        :accumulated_without_continuation -> :accumulated_progress
        :consumed_without_continuation -> :consumed_progress
        :operation_specific_continuation -> :consumed_progress
        other -> other
      end

    snapshot = make_snapshot.(base)
    owner = self()

    AppPolicy.interpret(snapshot, %ContextTrigger{},
      classify: fn input ->
        send(owner, {:input, input})
        {:ok, %{intent: "none", order: "unknown"}}
      end
    )

    input =
      receive do
        {:input, input} -> input
      after
        1000 -> raise "No input"
      end

    questions = Interpretation.questions(input)

    questions =
      cond do
        variant in [:accumulated_without_continuation, :consumed_without_continuation] ->
          update_in(questions["intent"].criteria, &Map.delete(&1, "handled_continuation"))

        variant == :operation_specific_continuation ->
          put_in(
            questions["intent"].criteria["handled_continuation"],
            "Only trailing words finishing the already handled delivery STATUS request for order 124. Asking what ITEMS are in the order changes the operation and is a NEW items request, never this choice."
          )

        true ->
          questions
      end

    answers =
      if cached do
        row =
          Enum.find(cached, &(&1["round"] == round and &1["variant"] == Atom.to_string(variant)))

        true = Jason.decode!(Jason.encode!(input)) == row["input"]

        Map.new(row["answers"], fn {key, answer} ->
          {key, %{choice: answer["choice"], probabilities: answer["probabilities"]}}
        end)
      else
        {:ok, response} =
          TypeSafe.system_one(OrderDesk.TypeSafe, state: input, questions: questions)

        Map.new(response.answers, fn {k, v} -> {k, Map.take(v, [:choice, :probabilities])} end)
      end

    judgment = Interpretation.interpret_answers(answers)

    {:ok, decisions} =
      AppPolicy.interpret(snapshot, %ContextTrigger{}, classify: fn _ -> judgment end)

    true = hd(decisions).kind == :start_task
    true = answers["target"].choice == "124"
    true = answers["target"].probabilities["124"] >= 0.8

    row = %{
      round: round,
      variant: variant,
      input: input,
      answers: answers,
      judgment: inspect(judgment),
      decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
    }

    IO.inspect(Map.take(row, [:round, :variant, :answers, :judgment, :decisions]),
      limit: :infinity
    )

    row
  end

unless cached,
  do:
    File.write!(
      output,
      Jason.encode!(
        %{
          provenance:
            "Constructed states, not original classifier responses. Current TypeSafe model/prompts; 0.8 threshold unchanged.",
          rows: rows
        },
        pretty: true
      ) <> "\n"
    )
