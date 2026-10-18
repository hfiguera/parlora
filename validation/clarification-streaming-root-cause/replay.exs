alias OrderDesk.{AppPolicy, CallerHistory, Interpretation, Speech}
alias Parlora.{ContextSnapshot, ContextTrigger}

capture = fn snapshot, judgment ->
  key = make_ref()

  {:ok, decisions} =
    AppPolicy.interpret(snapshot, %ContextTrigger{kind: :delegation, delegation_id: "z"},
      classify: fn state ->
        send(self(), {key, state})
        judgment
      end
    )

  state =
    receive do
      {^key, state} -> state
    after
      0 -> nil
    end

  %{
    state: state,
    decisions: Enum.map(decisions, &Map.take(&1, [:kind, :delegation_id, :message, :input]))
  }
end

marker = %{
  context_revision: 3,
  command_id: "question",
  message: "Please finish saying the three-digit order number.",
  input: %{}
}

fragments = [
  %{speaker: :user, delta: " four", arrival_order: 5, start_ms: 1100, end_ms: 1600},
  %{speaker: :assistant, delta: "Thanks for the", arrival_order: 4, start_ms: 600, end_ms: 1300},
  %{
    speaker: :user,
    delta: "Sorry, I mean one hundred twenty",
    arrival_order: 3,
    start_ms: 100,
    end_ms: 1000
  }
]

snapshot = %ContextSnapshot{
  session_id: "streaming-diagnosis",
  transcripts: fragments,
  pending_delegations: %{
    "z" => %{
      status: :pending,
      clarification: marker,
      context_wait: %{recheck_key: "5:verify", expired?: true}
    }
  }
}

split = capture.(snapshot, {:ok, %{intent: "status", order: "124"}})

control =
  capture.(
    update_in(snapshot.pending_delegations["z"], &Map.delete(&1, :clarification)),
    {:ok, %{intent: "status", order: "124"}}
  )

true = split.state == nil
true = hd(split.decisions).message =~ "finish"
true = hd(control.decisions).kind == :start_task
full_text = CallerHistory.text(fragments)
["124"] = Speech.numbers(full_text)

# Even a confidently interpretable operation is never visited by the short-tail guard.
initial = %{
  snapshot
  | transcripts: [
      %{
        speaker: :user,
        delta: "Check order one two",
        arrival_order: 5
      }
    ],
    pending_delegations: %{
      "z" => %{status: :pending, context_wait: %{recheck_key: "5:verify", expired?: true}}
    }
}

no_intent =
  capture.(
    initial,
    {:error, {:uncertain, %{intent: "status", order: "unknown", uncertain_fields: ["target"]}}}
  )

%{} = hd(no_intent.decisions).input
true = no_intent.state == nil

known = %{
  context_revision: 6,
  command_id: "operation-question",
  message: "For order 124, what would you like to check?",
  input: %{known_order: "124", known_operation: nil, missing: ["operation"]}
}

items = %ContextSnapshot{
  session_id: "items-diagnosis",
  transcripts: [
    %{speaker: :user, delta: "Do you know what items ordered", arrival_order: 8},
    %{speaker: :assistant, delta: "What do you want to know?", arrival_order: 7},
    %{speaker: :user, delta: "One hundred twenty four, one two four", arrival_order: 6},
    %{speaker: :assistant, delta: "Say the full number", arrival_order: 4},
    %{speaker: :user, delta: "Sorry, I mean one hundred twenty four", arrival_order: 3}
  ],
  pending_delegations: %{
    "z" => %{
      status: :pending,
      clarification: known,
      context_wait: %{recheck_key: "8:verify", expired?: true}
    }
  }
}

# Add an earlier pending delegation with an older question. Selection ignores trigger z.
multiple =
  put_in(items.pending_delegations["a"], %{
    status: :pending,
    clarification: marker,
    context_wait: %{recheck_key: "8:verify", expired?: true}
  })

uncertain = {:error, {:uncertain, %{intent: "items", order: "124", uncertain_fields: ["intent"]}}}
items_input = capture.(items, uncertain)
wrong_owner = capture.(multiple, uncertain)
true = items_input.state.clarification_reply.pending_request.known_order == "124"
true = wrong_owner.state.clarification_reply.pending_request == %{}
true = hd(wrong_owner.decisions).delegation_id == "a"

# Partially confident operation is discarded when the following number remains incomplete.
partial =
  put_in(initial.pending_delegations["z"][:clarification], %{
    known
    | context_revision: 3,
      input: %{known_order: nil, known_operation: "status", missing: ["order"]}
  })

kept_intent = capture.(partial, uncertain)
"status" = hd(kept_intent.decisions).input.known_operation

# A target-only uncertain judgment can generate a question about an already known operation.
items_target_uncertain =
  capture.(
    items,
    {:error, {:uncertain, %{intent: "items", order: "124", uncertain_fields: ["target"]}}}
  )

[] = hd(items_target_uncertain.decisions).input.missing
true = hd(items_target_uncertain.decisions).message =~ "are you asking"

controls = %{
  split_across_clarification: split,
  complete_without_marker: control,
  reconstructed_text: full_text,
  initial_incomplete_loses_intent: no_intent,
  existing_known_intent_preserved: kept_intent,
  one_pending: items_input,
  multiple_pending: wrong_owner,
  target_uncertainty_asks_operation: items_target_uncertain,
  literal_numbers:
    Map.new(
      [
        "one hornet twenty three",
        "one hundred twenty four",
        "One hundred twenty four, one two four"
      ],
      &{&1, Speech.numbers(&1)}
    )
}

live =
  if System.get_env("ORDER_DESK_TYPESAFE") == "1" do
    for round <- 1..2,
        {name, state} <- [
          {"items_known_pending", items_input.state},
          {"items_older_pending", wrong_owner.state}
        ] do
      {:ok, response} =
        TypeSafe.system_one(OrderDesk.TypeSafe,
          state: state,
          questions: Interpretation.questions(state)
        )

      judgment = Interpretation.interpret_answers(response.answers)
      chosen_snapshot = if name == "items_known_pending", do: items, else: multiple
      result = capture.(chosen_snapshot, judgment)

      record = %{
        round: round,
        name: name,
        judgment: inspect(judgment),
        result: result,
        answers:
          Map.new(response.answers, fn {key, answer} ->
            {key, Map.take(answer, [:choice, :probabilities])}
          end)
      }

      IO.puts(Jason.encode!(record))
      record
    end
  else
    []
  end

filename = if live == [], do: "controls.json", else: "results.json"

File.write!(
  Path.join(__DIR__, filename),
  Jason.encode!(%{controls: controls, live: live}, pretty: true) <> "\n"
)

IO.puts("Deterministic root-cause controls passed; evidence saved.")
