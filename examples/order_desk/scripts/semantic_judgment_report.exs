# Opt-in real JEV evaluation. Synthetic transcripts; no backend task execution or saves.
Logger.configure(level: :error)

{options, arguments, invalid} =
  OptionParser.parse(System.argv(), strict: [models: :string, repeats: :integer, replay: :string])

unless is_binary(options[:replay]) or Process.whereis(OrderDesk.TypeSafe),
  do: raise("Enable TypeSafe with TYPESAFE_API_KEY before running this report")

models = String.split(options[:models] || "jev-1.13.0", ",", trim: true)
repeats = options[:repeats] || 1

unless invalid == [] and length(arguments) <= 1 and models != [] and
         Enum.all?(models, &(&1 in ["jev-1.13.0", "jev-1.14.0"])) and repeats in 1..3,
       do:
         raise(
           "Use [OUTPUT.json] [--models jev-1.13.0,jev-1.14.0] [--repeats 1..3] [--replay SAVED.json]"
         )

output = List.first(arguments) || "/tmp/parlora-jev-semantic-judgments.json"

handled_text = fn
  "delivery" -> "Leave with my neighbor"
  "items" -> "What items are in order 123?"
  "instructions" -> "What are the delivery instructions for order 123?"
  "status" -> "Check order 123"
end

alias Parlora.{ContextSnapshot, ContextTrigger}

base_task = fn op ->
  %{
    revision: 1,
    status: :running,
    request_ids: [],
    input: %{
      order: "123",
      operation: op,
      instructions: if(op == "delivery", do: "Leave with my neighbor"),
      request_text: handled_text.(op),
      user_revision: 1
    }
  }
end

make = fn name, op, fresh, after_assistant, marker ->
  handled = handled_text.(op)

  captions =
    [{:user, handled}] ++
      if(after_assistant, do: [{:assistant, "Please review the draft on the page."}], else: []) ++
      [{:user, fresh}]

  transcripts =
    captions
    |> Enum.with_index(1)
    |> Enum.map(fn {{speaker, delta}, n} ->
      %{speaker: speaker, delta: delta, arrival_order: n, timing: :unavailable}
    end)
    |> Enum.reverse()

  revision = length(captions)

  task =
    base_task.(op) |> Map.put(:context_wait, %{expired?: true, recheck_key: "#{revision}:verify"})

  task =
    if marker,
      do:
        Map.put(task, :clarification, %{
          context_revision: 1,
          input: marker,
          message: "In addition or instead?"
        }),
      else: task

  %ContextSnapshot{
    session_id: name,
    revision: revision,
    provider_speech: :idle,
    application_context: %{voice_provider: :gemini},
    transcripts: transcripts,
    tasks: %{"active" => task},
    pending_delegations: %{"d" => %{status: :pending}}
  }
end

relation = %{known_order: "124", known_operation: "status", missing: ["relationship"]}

cases = [
  {"presence", "instructions", "Are you still there?", false, nil, ["presence"], nil},
  {"audibility", "status", "Hello, can you hear me?", false, nil, ["presence"], nil},
  {"presence_spanish", "status", "¿Sigues ahí? ¿Me escuchas?", false, nil, ["presence"], nil},
  {"presence_with_business", "status", "Are you there? Check order 124.", false, nil, ["status"],
   false},
  {"progress", "instructions", "Are you still checking?", false, nil, ["followup"], nil},
  {"draft_restatement", "delivery", "Yes.I want to change the delivery instructions.", false, nil,
   ["delivery_continuation"], nil},
  {"draft_restatement_paraphrase", "delivery", "That's the delivery change I'm requesting.",
   false, nil, ["delivery_continuation", "none"], nil},
  {"draft_new_request", "delivery", "I want to change the delivery instructions.", true, nil,
   ["delivery"], nil},
  {"draft_new_destination", "delivery", "Actually, leave at reception.", false, nil, ["delivery"],
   nil},
  {"draft_refusal", "delivery", "No, don't change it. Keep the original instructions.", false,
   nil, ["refuse"], nil},
  {"draft_cancel", "delivery", "Cancel that change.", false, nil, ["refuse", "cancel"], nil},
  {"draft_other_order", "delivery", "I want to change the delivery instructions for order 124.",
   false, nil, ["delivery"], false},
  {"addition_too", "status", "Check 124 too, keep checking 123.", false, nil, ["status"], true},
  {"addition_parallel", "items",
   "Keep the first request and check the items in 124 as a separate request.", false, nil,
   ["items"], true},
  {"replacement_another", "status", "Sorry, I meant another order, 124.", false, nil, ["status"],
   false},
  {"replacement_switch", "status", "Switch the lookup to 124 instead of 123.", false, nil,
   ["status"], false},
  {"relationship_reply_add", "status", "Keep both.", false, relation, ["status"], true},
  {"relationship_reply_replace", "status", "Replace the previous one.", false, relation,
   ["status"], false}
]

cases =
  Enum.map(cases, fn {name, op, fresh, after_assistant, marker, intents, additional} ->
    %{
      name: name,
      snapshot: make.(name, op, fresh, after_assistant, marker),
      intents: intents,
      additional: additional,
      order: if(additional != nil or marker, do: "124", else: "123"),
      work: nil,
      kinds: nil
    }
  end)

# Exercise the same streaming boundaries as the deterministic regression tests.
# Expected outcomes are fixed before either model runs. These snapshots never
# execute backend work; only AppPolicy's proposed decisions are inspected.
read_case = fn name, operation, order, handled, fresh, assistant, expected, task_status ->
  captions =
    if(operation, do: [{:user, handled}], else: []) ++
      if(assistant, do: [{:assistant, assistant}], else: []) ++ [{:user, fresh}]

  revision = length(captions)

  task = %{
    revision: 1,
    status: task_status,
    input: %{order: order, operation: operation, user_revision: 1, request_text: handled},
    context_wait: %{expired?: true, recheck_key: "#{revision}:verify"}
  }

  snapshot = %ContextSnapshot{
    session_id: name,
    revision: revision,
    provider_speech: :idle,
    application_context: %{voice_provider: :openai},
    tasks: if(operation, do: %{"active" => task}, else: %{}),
    pending_delegations: %{
      "d" => %{
        status: :pending,
        context_wait: %{expired?: true, recheck_key: "#{revision}:verify"}
      }
    },
    transcripts:
      captions
      |> Enum.with_index(1)
      |> Enum.map(fn {{speaker, delta}, n} ->
        %{speaker: speaker, delta: delta, arrival_order: n, timing: :unavailable}
      end)
      |> Enum.reverse()
  }

  Map.merge(
    %{
      name: name,
      snapshot: snapshot,
      intents: nil,
      additional: nil,
      order: nil,
      work: nil,
      kinds: nil
    },
    expected
  )
end

new_read = fn operation, order ->
  %{work: %{operation: operation, order: order}, kinds: [:start_task, :supersede_task]}
end

continuation = %{intents: ["handled_continuation"], order: "825", kinds: [:associate_delegation]}
clarify = %{kinds: [:request_clarification]}

extra_cases = [
  {"initial_presence_without_order", nil, nil, nil, "Can you hear me?", nil,
   %{intents: ["presence"], kinds: [:wait_for_context]}, :running},
  {"presence_after_unfinished_read", "items", "825", "Do you know what items are",
   "Are you there?", "Order eight twenty five has three notebooks.",
   %{intents: ["presence"], kinds: [:associate_delegation]}, :completed},
  {"initial_status", nil, nil, nil, "Check order 123", nil, new_read.("status", "123"), :running},
  {"initial_spoken_825", nil, nil, nil, "Check order eight twenty five", nil,
   new_read.("status", "825"), :running},
  {"initial_items", nil, nil, nil, "What items are in order 124?", nil, new_read.("items", "124"),
   :running},
  {"initial_instructions", nil, nil, nil, "What are the saved instructions for order 825?", nil,
   new_read.("instructions", "825"), :running},
  {"completed_status_to_items", "status", "825", "Check order 825", "What items are in it?",
   "It is processing.", new_read.("items", "825"), :completed},
  {"completed_items_to_status", "items", "825", "What items are in order 825?",
   "What is the delivery status?", "It contains three notebooks.", new_read.("status", "825"),
   :completed},
  {"completed_items_to_instructions", "items", "825", "What items are in order 825?",
   "What are the saved delivery instructions?", "It contains three notebooks.",
   new_read.("instructions", "825"), :completed},
  {"running_items_suffix", "items", "825", "Do you know what items are", " there", "Yep.",
   continuation, :running},
  {"completed_items_suffix", "items", "825", "Do you know what items are", " there",
   "Order eight twenty five has three notebooks.", continuation, :completed},
  {"running_status_suffix", "status", "825", "Can you check order 825", " for me", "Sure.",
   continuation, :running},
  {"completed_instructions_suffix", "instructions", "825", "What are the saved instructions",
   " for that order", "There are no saved instructions.", continuation, :completed},
  {"fresh_retry", "status", "825", "Check order 825", "Check it again", "It is processing.",
   Map.merge(new_read.("status", "825"), %{intents: ["retry_lookup"]}), :completed},
  {"explicit_numeric_correction", "status", "123", "Check order 123", "Sorry, I mean 825",
   "It is shipped.", new_read.("status", "825"), :completed},
  {"explicit_items_correction", "items", "825", "What items are in order 825?",
   "Sorry, I mean order 124", "There are three notebooks.", new_read.("items", "124"),
   :completed},
  {"pending_spoken_correction", "status", "123", "Check order 123",
   "Actually, check the delivery status of order eight twenty five instead", "Checking.",
   new_read.("status", "825"), :running},
  {"correction_with_new_operation", "status", "123", "Check order 123",
   "Actually, what items are in order 825?", "Checking.", new_read.("items", "825"), :running},
  {"unknown_other_order", "items", "825", "What items are in order 825?",
   "Check the items in a different order", "There are three notebooks.", clarify, :completed},
  {"unfinished_correction", "status", "123", "Check order 123", "Actually, order eight two",
   "It is shipped.", clarify, :completed},
  {"conflicting_numbers", "status", "825", "Check order 825",
   "Check either order 123 or 124, I am not sure which", "It is processing.", clarify,
   :completed},
  {"invalid_A25", nil, nil, nil, "Check order A25", nil, clarify, :running},
  {"spoken_yes_cannot_save", "delivery", "123", "Leave with my neighbor", "Yes, save it",
   "Press Confirm on the page to save the draft.",
   %{intents: ["none"], kinds: [:associate_delegation]}, :completed}
]

extra_cases =
  Enum.map(extra_cases, fn {name, op, order, handled, fresh, assistant, expected, status} ->
    read_case.(name, op, order, handled, fresh, assistant, expected, status)
  end)

retry_suffix =
  read_case.(
    "already_admitted_retry_suffix",
    "status",
    "825",
    "Please try",
    " checking that order again",
    "Sure.",
    continuation,
    :completed
  )

retry_suffix = put_in(retry_suffix.snapshot.tasks["active"].input[:retry?], true)

number_suffix =
  read_case.(
    "completed_numeric_prefix_correction",
    "status",
    "120",
    "Check order 120",
    " three",
    "It is processing.",
    new_read.("status", "123"),
    :completed
  )

reply_case =
  read_case.(
    "pending_items_number_reply",
    "status",
    "123",
    "Check order 123",
    "one two four",
    "Which order's items?",
    new_read.("items", "124"),
    :completed
  )

reply_case =
  put_in(reply_case.snapshot.tasks["active"][:clarification], %{
    context_revision: 2,
    message: "Which order's items?",
    input: %{known_order: nil, known_operation: "items", missing: ["order"]}
  })

retained_case =
  read_case.(
    "pending_operation_keeps_clarified_order",
    "status",
    "124",
    "Check order 124",
    "What items are in that order?",
    "For order 123, what would you like to check?",
    new_read.("items", "123"),
    :completed
  )

retained_case =
  put_in(retained_case.snapshot.tasks["active"][:clarification], %{
    context_revision: 2,
    message: "For order 123, what would you like to check?",
    input: %{known_order: "123", known_operation: nil, missing: ["operation"]}
  })

pending_presence =
  read_case.(
    "presence_during_business_clarification",
    "status",
    "123",
    "Check order 123",
    "Can you hear me?",
    "Which order's items?",
    %{intents: ["presence"], kinds: [:wait_for_context]},
    :completed
  )

pending_presence =
  put_in(pending_presence.snapshot.tasks["active"][:clarification], %{
    context_revision: 2,
    message: "Which order's items?",
    input: %{known_order: nil, known_operation: "items", missing: ["order"]}
  })

cases =
  cases ++
    extra_cases ++ [reply_case, retained_case, retry_suffix, number_suffix, pending_presence]

replay =
  if options[:replay] do
    saved = options[:replay] |> File.read!() |> Jason.decode!()
    Map.new(saved["results"], &{{&1["name"], &1["pass"], &1["requested_model"]}, &1})
  end

cases =
  if replay do
    names = replay |> Map.keys() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    selected = Enum.filter(cases, &MapSet.member?(names, &1.name))

    unless length(selected) == MapSet.size(names) and selected != [],
      do: raise("Saved report must contain known nonempty cases")

    selected
  else
    cases
  end

results =
  for pass <- 1..repeats, item <- cases, model <- models do
    snapshot = item.snapshot
    Process.delete(:judgment)
    Process.delete(:answers)
    Process.delete(:returned_model)
    Process.delete(:input)

    capture = fn state ->
      reply =
        if replay do
          saved = Map.fetch!(replay, {item.name, pass, model})

          unless saved["returned_model"] == model and
                   Jason.decode!(Jason.encode!(state)) == saved["input"],
                 do: raise("Replay context or classification boundary changed: #{item.name}")

          {:ok,
           %{
             model: model,
             answers:
               Map.new(saved["answers"], fn {key, value} ->
                 {key, %{choice: value["choice"], probabilities: value["probabilities"]}}
               end)
           }}
        else
          TypeSafe.system_one(OrderDesk.TypeSafe,
            state: state,
            questions: OrderDesk.Interpretation.questions(state),
            model: model,
            retry: [max_attempts: 1]
          )
        end

      judgment =
        case reply do
          {:ok, response} -> OrderDesk.Interpretation.interpret_answers(response.answers, state)
          {:error, error} -> {:error, error.kind}
        end

      Process.put(:judgment, judgment)
      Process.put(:input, state)

      Process.put(
        :returned_model,
        case reply do
          {:ok, response} -> response.model
          _ -> nil
        end
      )

      Process.put(
        :answers,
        case reply do
          {:ok, r} ->
            Map.new(r.answers, fn {k, v} -> {k, Map.take(v, [:choice, :probabilities])} end)

          _ ->
            %{}
        end
      )

      judgment
    end

    started = System.monotonic_time(:millisecond)

    {:ok, decisions} =
      OrderDesk.AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: capture,
        clarification_window: fn _ -> 0 end
      )

    judgment = Process.get(:judgment)

    judgment_passed =
      case judgment do
        {:ok, j} ->
          (is_nil(item.intents) or j.intent in item.intents) and
            (is_nil(item.order) or j.intent == "presence" or j.order == item.order) and
            (is_nil(item.additional) or Map.get(j, :additional?) == item.additional)

        _ ->
          is_nil(item.intents)
      end

    work = Enum.filter(decisions, &(&1.kind in [:start_task, :supersede_task]))

    policy_passed =
      (is_nil(item.kinds) or Enum.any?(decisions, &(&1.kind in item.kinds))) and
        if(item.work,
          do:
            length(work) == 1 and
              Enum.all?(work, &(Map.take(&1.input, [:order, :operation]) == item.work)),
          else: is_nil(item.kinds) or work == []
        )

    returned_model = Process.get(:returned_model)
    passed = judgment_passed and policy_passed and (is_nil(judgment) or returned_model == model)

    record = %{
      name: item.name,
      pass: pass,
      requested_model: model,
      returned_model: returned_model,
      passed: passed,
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      judgment: inspect(judgment),
      answers: Process.get(:answers),
      input: Process.get(:input),
      expected: Map.drop(item, [:snapshot, :name]),
      previously_passed: if(replay, do: Map.fetch!(replay, {item.name, pass, model})["passed"]),
      decisions: Enum.map(decisions, &Map.from_struct/1)
    }

    IO.puts(
      Jason.encode!(
        Map.take(record, [
          :name,
          :pass,
          :requested_model,
          :returned_model,
          :passed,
          :elapsed_ms,
          :judgment
        ])
      )
    )

    record
  end

File.write!(
  output,
  Jason.encode!(
    %{
      method:
        if(replay,
          do:
            "Saved typed answers replayed through real AppPolicy with identical verified input states; no API calls. Model fields identify the original observations, not new service responses.",
          else:
            "Identical synthetic dialogue snapshots evaluated sequentially with each pinned live model and real AppPolicy; no cache, retries, backend execution, or real order writes. Nil returned_model means deterministic policy handling bypassed JEV."
        ),
      mode: if(replay, do: "frozen_replay", else: "live"),
      replay_source_sha256:
        if(replay,
          do: :crypto.hash(:sha256, File.read!(options[:replay])) |> Base.encode16(case: :lower)
        ),
      newly_failed: Enum.count(results, &(&1.previously_passed == true and not &1.passed)),
      recorded_at: DateTime.utc_now(),
      models: models,
      repeats: repeats,
      cases: length(cases),
      results: results
    },
    pretty: true
  )
)

IO.puts(
  "#{Enum.count(results, & &1.passed)}/#{length(results)} scenarios passed; numeric judgments written to #{output}"
)

if Enum.any?(results, &(not &1.passed)), do: System.halt(1)
