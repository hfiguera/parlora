# Offline causal replay of frozen live responses. No TypeSafe API call is made.
Logger.configure(level: :error)
[input, output] = System.argv()
source = input |> File.read!() |> Jason.decode!()
alias OrderDesk.{AppPolicy, Interpretation}
alias Parlora.{ContextSnapshot, ContextTrigger}

rows =
  for row <- source["results"], row["name"] == "completed_items_suffix" do
    task = row["input"]["active_task"]

    snapshot = %ContextSnapshot{
      session_id: "frozen-speech-act",
      revision: 3,
      application_context: %{voice_provider: :openai},
      provider_speech: :idle,
      tasks: %{
        "active" => %{
          revision: 1,
          status: :completed,
          input: %{
            operation: task["operation"],
            order: task["order"],
            user_revision: 1,
            request_text: row["input"]["handled_caller_input"]
          },
          context_wait: %{expired?: true, recheck_key: "3:verify"}
        }
      },
      pending_delegations: %{"d" => %{status: :pending}},
      transcripts:
        row["input"]["recent_dialogue"]
        |> Enum.with_index(1)
        |> Enum.map(fn {caption, revision} ->
          %{
            speaker: if(caption["speaker"] == "user", do: :user, else: :assistant),
            delta: caption["text"],
            arrival_order: revision
          }
        end)
        |> Enum.reverse()
    }

    answers =
      Map.new(row["answers"], fn {key, value} ->
        {key, %{choice: value["choice"], probabilities: value["probabilities"]}}
      end)

    # A controlled label permutation with the same selected-option probability.
    # This is a local counterfactual, not a new or fabricated JEV observation.
    probabilities = answers["speech_act"].probabilities

    neutral = %{
      choice: "other",
      probabilities: %{
        "other" => probabilities["presence"],
        "presence" => probabilities["other"],
        "uncertain" => probabilities["uncertain"]
      }
    }

    variants = [
      {"captured", answers},
      {"omit_auxiliary_answer", Map.delete(answers, "speech_act")},
      {"equally_uncertain_other", Map.put(answers, "speech_act", neutral)}
    ]

    for {variant, replay_answers} <- variants do
      {:ok, decisions} =
        AppPolicy.interpret(snapshot, %ContextTrigger{},
          classify: fn state ->
            judgment = Interpretation.interpret_answers(replay_answers, state)
            Process.put(:replay_judgment, judgment)
            judgment
          end
        )

      judgment = Process.get(:replay_judgment)

      expected? =
        case {variant, judgment} do
          {"captured",
           {:error,
            {:uncertain,
             %{intent: "presence", order: "unknown", uncertain_fields: ["speech_act"]}}}} ->
            Enum.any?(decisions, &(&1.kind == :request_clarification))

          {variant, {:ok, %{intent: "handled_continuation", order: "825"}}}
          when variant in ["omit_auxiliary_answer", "equally_uncertain_other"] ->
            Enum.map(decisions, & &1.kind) == [:associate_delegation]

          _ ->
            false
        end

      unless expected?, do: raise("Causal replay changed: #{row["requested_model"]} #{variant}")

      %{
        source_model: row["requested_model"],
        source_pass: row["pass"],
        variant: variant,
        observed_expected_behavior: expected?,
        judgment: inspect(judgment),
        decisions: Enum.map(decisions, &Map.take(&1, [:kind, :message, :input]))
      }
    end
  end
  |> List.flatten()

File.write!(
  output,
  Jason.encode!(
    %{
      method:
        "Frozen answers from six completed-items live observations; real interpretation and AppPolicy; no API calls. Auxiliary-answer omissions and label permutations are explicitly local counterfactuals, not service observations.",
      recorded_at: DateTime.utc_now(),
      source_sha256: :crypto.hash(:sha256, File.read!(input)) |> Base.encode16(case: :lower),
      results: rows
    },
    pretty: true
  ) <> "\n"
)

IO.puts("#{length(rows)} frozen-answer causal replays verified")
