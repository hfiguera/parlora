defmodule OrderDesk.AppPolicy do
  @moduledoc "TypeSafe-assisted interpretation with application-owned task mapping and literal extraction."
  @behaviour Parlora.ContextPolicy
  alias Parlora.ContextDecision, as: Decision
  alias OrderDesk.{Clarification, Recovery}

  @impl true
  def interpret(snapshot, trigger, opts) do
    result =
      do_interpret(snapshot, trigger, opts)
      |> Clarification.coordinate(snapshot, opts)
      |> continue_pending(snapshot)

    OrderDesk.Interpretation.trace(%{
      kind: "policy_proposal",
      session_id: snapshot.session_id,
      context_revision: snapshot.revision,
      pending: snapshot.pending_delegations,
      transcripts: snapshot.transcripts,
      result: inspect(result, limit: 100, printable_limit: 4096)
    })

    result
  end

  # Claiming a first request may leave later provider delegations waiting with no
  # further caller speech. Revisit once per remaining entry against the new task.
  defp continue_pending({:ok, decisions}, snapshot) do
    if Enum.any?(decisions, &(&1.kind in [:start_task, :associate_delegation])) do
      targeted = Enum.map(decisions, & &1.delegation_id)

      remaining = %{
        snapshot
        | pending_delegations: Map.drop(snapshot.pending_delegations, targeted)
      }

      {:ok,
       decisions ++
         association_recheck(
           Recovery.pending(remaining),
           OrderDesk.CallerHistory.revision(snapshot.transcripts)
         )}
    else
      {:ok, decisions}
    end
  end

  defp do_interpret(snapshot, trigger, opts) do
    active =
      Enum.max_by(
        snapshot.tasks,
        fn {_id, task} -> Map.get(task.input, :user_revision, 0) end,
        fn -> nil end
      )

    pending = Recovery.pending(snapshot)

    text =
      snapshot.transcripts
      |> OrderDesk.CallerHistory.text()
      |> OrderDesk.Speech.join_number_segments()
      |> String.slice(-4_000, 4_000)

    revision = OrderDesk.CallerHistory.revision(snapshot.transcripts)

    recovery = Recovery.new(active, pending, revision, opts)
    latest_segment = OrderDesk.CallerHistory.latest(snapshot.transcripts)

    cond do
      text == "" or (active == nil and pending == nil) ->
        {:ok, []}

      OrderDesk.Speech.social?(latest_segment) ->
        {:ok, associate(active, pending)}

      refusal_continuation?(snapshot, active) ->
        {:ok, associate(active, pending)}

      Recovery.awaiting_reply?(recovery) ->
        {:ok, Recovery.wait(recovery)}

      correction = read_correction(snapshot, active, recovery) ->
        {:ok, decisions({:ok, correction}, snapshot, active, pending, text, revision, recovery)}

      active != nil and elem(active, 1).input[:user_revision] == revision ->
        {:ok, associate(active, pending)}

      OrderDesk.Speech.incomplete_number?(current_input(snapshot, active)) and
          Recovery.number_ready?(recovery) ->
        {:ok,
         Recovery.decide(
           recovery,
           "Please finish saying the three-digit order number.",
           Clarification.number_input(recovery, current_input(snapshot, active))
         )}

      OrderDesk.Speech.open_number?(current_input(snapshot, active)) and
          not Recovery.number_ready?(recovery) ->
        {:ok, Recovery.wait_for_number(recovery)}

      partial = Clarification.number_reply(recovery, current_input(snapshot, active)) ->
        {:ok, Recovery.decide(recovery, Clarification.question(partial), partial)}

      defer_assistant?(snapshot, trigger) ->
        OrderDesk.Interpretation.defer(snapshot.session_id)
        delay = 200

        # Speech-idle updates revise the snapshot but do not trigger policy execution.
        # A single renewable recheck keeps deferred caller work from being stranded.
        wait = %{
          recovery.target
          | kind: :wait_for_context,
            recheck_after_ms: delay,
            recheck_key: "interpret:#{revision}:#{System.monotonic_time(:millisecond)}"
        }

        {:ok, [wait]}

      true ->
        active_input =
          if active, do: describe_task(elem(active, 1)), else: nil

        candidates =
          OrderDesk.Speech.numbers(text) ++
            OrderDesk.Speech.numbers(current_input(snapshot, active)) ++
            if(active_input, do: [active_input.order], else: []) ++
            List.wrap(get_in(recovery, [:entry, :clarification, :input, :known_order])) ++
            List.wrap(get_in(recovery, [:entry, :clarification, :input, :candidate_order]))

        # Keep semantic lifecycle state in the cache key, but omit IDs and volatile counters.
        state = %{
          caller_history: text,
          recent_dialogue: OrderDesk.CallerHistory.dialogue(snapshot.transcripts),
          latest_caller_segment: latest_segment,
          active_task: active_input,
          new_caller_text: current_input(snapshot, active),
          handled_caller_input: handled_input(snapshot, active),
          delivery_continuation_eligible: delivery_continuation_eligible?(snapshot, active),
          clarification_reply: clarification_reply(snapshot, recovery, active_input),
          delivery_drafts: OrderDesk.Drafts.context(snapshot),
          recent_work:
            snapshot.tasks
            |> Map.values()
            |> Enum.sort_by(&Map.get(&1.input, :user_revision, 0), :desc)
            |> Enum.take(16)
            |> Enum.map(&describe_task/1),
          order_candidates: candidates |> Enum.uniq() |> Enum.take(-32)
        }

        classify =
          Keyword.get(opts, :classify, fn input ->
            OrderDesk.Interpretation.classify(input,
              fresh?: Recovery.verifying?(recovery),
              session_id: snapshot.session_id,
              context_revision: snapshot.revision
            )
          end)

        case classify.(state) do
          {:error, :superseded} -> {:ok, []}
          result -> {:ok, decisions(result, snapshot, active, pending, text, revision, recovery)}
        end
    end
  end

  defp defer_assistant?(
         %{provider_speech: :speaking, transcripts: [%{speaker: :assistant} | _]},
         %{kind: kind}
       )
       when kind in [:transcript_updated, :context_wait_expired], do: true

  defp defer_assistant?(_snapshot, _trigger), do: false

  defp decisions(
         {:ok, %{intent: "presence"}},
         _snapshot,
         active,
         pending,
         _text,
         _revision,
         recovery
       ) do
    if active != nil and is_nil(recovery.entry[:clarification]),
      do: associate(active, pending),
      else: Recovery.wait(recovery)
  end

  defp decisions(
         {:ok, %{intent: "delivery_continuation", order: order}} = answer,
         snapshot,
         {_id, task} = active,
         pending,
         _text,
         _revision,
         recovery
       ) do
    if delivery_continuation_eligible?(snapshot, active) and task.input.order == order,
      do: associate(active, pending),
      else: clarify(recovery, elem(answer, 1), snapshot, active)
  end

  defp decisions(
         {:ok, %{intent: "none"}},
         _snapshot,
         active,
         pending,
         _text,
         _revision,
         _recovery
       ),
       do: associate(active, pending)

  defp decisions(
         {:ok, %{intent: "handled_continuation", order: order}} = answer,
         snapshot,
         {_id, task} = active,
         pending,
         _text,
         _revision,
         recovery
       ) do
    fresh = current_input(snapshot, active)

    if task.input.operation in ["status", "items", "instructions"] and
         task.input.order == order and
         is_nil(clarification_reply(snapshot, recovery, describe_task(task))) and
         OrderDesk.Speech.numbers(fresh) in [[], [order]] and
         not OrderDesk.Speech.changed_order_reference?(fresh) do
      associate(active, pending)
    else
      clarify(recovery, elem(answer, 1), snapshot, active)
    end
  end

  defp decisions(
         {:ok, %{intent: "refuse", order: order}},
         snapshot,
         active,
         pending,
         _text,
         revision,
         recovery
       )
       when order != "unknown" do
    OrderDesk.Drafts.refuse(
      snapshot,
      order,
      revision,
      pending,
      recovery,
      current_input(snapshot, active)
    )
  end

  defp decisions(
         {:ok, %{intent: "followup", order: order}},
         snapshot,
         _active,
         pending,
         _text,
         _revision,
         recovery
       )
       when order != "unknown" do
    matching =
      snapshot.tasks
      |> Enum.filter(fn {_id, task} -> task.input.order == order end)
      |> Enum.max_by(fn {_id, task} -> Map.get(task.input, :user_revision, 0) end, fn -> nil end)

    if matching,
      do: associate(matching, pending),
      else:
        Recovery.decide(
          recovery,
          "What would you like to check about order #{order}: delivery status or items?"
        )
  end

  # Explicit retries are new read attempts, even for identical business input.
  # Anchor admission to the prior task; never replay a draft or a write action.
  defp decisions(
         {:ok, %{intent: "retry_lookup", order: order}} = answer,
         snapshot,
         {_id, task} = active,
         _pending,
         _text,
         revision,
         recovery
       ) do
    if task.input.operation in ["status", "items", "instructions"] and
         task.input.order == order do
      input = %{
        order: order,
        operation: task.input.operation,
        retry?: true,
        instructions: nil,
        actor: Map.get(snapshot.application_context, :actor, "local"),
        user_revision: revision,
        request_text: current_input(snapshot, active)
      }

      followup(active, input)
    else
      clarify(recovery, elem(answer, 1), snapshot, active)
    end
  end

  defp decisions(
         {:ok, %{intent: intent, order: order} = judgment},
         snapshot,
         active,
         pending,
         _text,
         revision,
         recovery
       )
       when intent in ["status", "items", "instructions", "delivery", "cancel"] and
              order != "unknown" do
    literal =
      if intent == "delivery",
        do: OrderDesk.Speech.delivery(current_input(snapshot, active)),
        else: nil

    cond do
      intent == "delivery" and literal == nil ->
        Recovery.decide(
          recovery,
          missing_delivery_message(snapshot, order),
          %{known_order: order, known_operation: "delivery", missing: ["instructions"]}
        )

      intent == "delivery" and not Recovery.delivery_ready?(recovery) ->
        Recovery.wait_for_delivery(recovery)

      true ->
        input = %{
          order: order,
          operation: intent,
          instructions: literal,
          actor: Map.get(snapshot.application_context, :actor, "local"),
          user_revision: revision,
          additional?: Map.get(judgment, :additional?, false),
          request_text: current_input(snapshot, active)
        }

        case active do
          {id, task} ->
            old = task.input

            cond do
              same?(old, input) ->
                associate(active, pending)

              input.additional? and pending ->
                start(pending, input)

              input.additional? ->
                followup(active, input)

              old.operation == intent or intent == "cancel" ->
                [
                  %Decision{
                    kind: :supersede_task,
                    delegation_id: pending && elem(pending, 0),
                    task_id: id,
                    expected_task_revision: task.revision,
                    input: input
                  }
                ]

              pending ->
                start(pending, input)

              true ->
                followup(active, input)
            end

          nil ->
            if pending, do: start(pending, input), else: []
        end
    end
  end

  defp decisions(
         {:error, {:uncertain, judgment}},
         snapshot,
         active,
         _pending,
         _text,
         _revision,
         recovery
       ),
       do: clarify(recovery, judgment, snapshot, active)

  defp decisions({:ok, judgment}, snapshot, active, _pending, _text, _revision, recovery),
    do: clarify(recovery, judgment, snapshot, active)

  defp decisions({:error, reason}, _snapshot, _active, _pending, _text, _revision, recovery)
       when reason != :uncertain,
       do:
         Recovery.decide(
           recovery,
           "The request interpreter is unavailable. Please try again, or use the order page to review saved instructions and drafts."
         )

  defp decisions(_unclear, _snapshot, _active, _pending, _text, _revision, recovery),
    do:
      Recovery.decide(
        recovery,
        "Please clarify the request and say the three-digit order number."
      )

  defp clarify(recovery, judgment, snapshot, active) do
    input =
      Clarification.input(
        judgment,
        current_input(snapshot, active),
        current_order_question?(judgment, snapshot, active),
        recovery
      )

    Recovery.decide(
      recovery,
      Clarification.question(input),
      Clarification.remember(input, current_input(snapshot, active))
    )
  end

  # This only chooses a clarification question. It never promotes an uncertain
  # judgment to executable work or fills an unknown target from history.
  defp current_order_question?(%{order: order} = judgment, snapshot, {_id, task} = active) do
    text = current_input(snapshot, active)

    uncertain_intent =
      judgment.intent == "unclear" or "intent" in Map.get(judgment, :uncertain_fields, [])

    order == task.input.order and uncertain_intent and
      OrderDesk.Speech.numbers(text) in [[], [order]] and
      not OrderDesk.Speech.changed_order_reference?(text)
  end

  defp current_order_question?(_judgment, _snapshot, _active), do: false

  defp read_correction(snapshot, {_id, task}, recovery) do
    fresh = current_input(snapshot, {nil, task})

    latest =
      snapshot.transcripts
      |> Enum.filter(&(Map.get(&1, :arrival_order, 0) > task.input.user_revision))
      |> OrderDesk.CallerHistory.latest()

    pending = get_in(recovery, [:entry, :clarification, :input]) || %{}

    retained_read? =
      pending == %{} or pending[:known_operation] in ["status", "items", "instructions"] or
        pending[:candidate_operation] in ["status", "items", "instructions"] or
        OrderDesk.Speech.read_correction(pending[:request_text] || "") != nil

    # Only an explicit correction of a read may retain the admitted operation.
    # Never borrow it for a pending write, cancellation, refusal, or a new question.
    if retained_read? and task.input.operation in ["status", "items", "instructions"] and
         pending[:known_operation] in [nil, "status", "items", "instructions"] and
         pending[:candidate_operation] in [nil, "status", "items", "instructions"] do
      if order =
           OrderDesk.Speech.read_correction(latest) || OrderDesk.Speech.read_correction(fresh),
         do: %{
           intent:
             pending[:known_operation] || pending[:candidate_operation] || task.input.operation,
           order: order
         }
    end
  end

  defp read_correction(_snapshot, _active, _recovery), do: nil

  defp delivery_continuation_eligible?(
         snapshot,
         {_id, %{input: %{operation: "delivery"}} = task} = active
       ) do
    fresh = latest_input(snapshot, active)

    # Only a literal-preserving restatement in the same uninterrupted caller run
    # may associate existing work. An assistant response, pending clarification,
    # different destination or new request must not borrow the old authorization.
    is_nil(task[:clarification]) and is_binary(task.input[:instructions]) and
      task.input.instructions != "" and
      OrderDesk.Speech.delivery(handled_input(snapshot, active)) == task.input.instructions and
      OrderDesk.Speech.delivery(fresh) == nil and
      OrderDesk.Speech.numbers(fresh) in [[], [task.input.order]] and
      not Enum.any?(snapshot.transcripts, fn fragment ->
        fragment.speaker == :assistant and
          Map.get(fragment, :arrival_order, 0) > task.input.user_revision
      end)
  end

  defp delivery_continuation_eligible?(_snapshot, _active), do: false

  defp missing_delivery_message(snapshot, order) do
    draft =
      snapshot
      |> OrderDesk.Drafts.context()
      |> Enum.find(&(&1.order == order and &1.status == "pending"))

    existing =
      if draft,
        do: "An existing draft for order #{order} says: #{draft.instructions}. ",
        else: ""

    existing <>
      "The new edit request is missing its delivery wording. Ask for the exact new instructions. " <>
      "This clarification does not create a draft, change an existing draft, or save instructions. " <>
      "Do not claim that existing drafts or running work are absent. Only browser confirmation saves a draft."
  end

  defp describe_task(task),
    do:
      task.input
      |> Map.take([:order, :operation, :retry?])
      |> Map.put(:status, Map.get(task, :status, :unknown))

  defp latest_input(snapshot, active) do
    revision = if active, do: elem(active, 1).input.user_revision, else: -1

    snapshot.transcripts
    |> Enum.filter(&(Map.get(&1, :arrival_order, 0) > revision))
    |> OrderDesk.CallerHistory.text()
    |> OrderDesk.Speech.join_number_segments()
    |> String.slice(-4_000, 4_000)
  end

  # A task can finish before the caller finishes a number. Reconstruct that request
  # instead of presenting its last word as a new request anchored to the old ID.
  defp current_input(snapshot, active) do
    fresh = latest_input(snapshot, active)
    handled = handled_input(snapshot, active)

    entry =
      if active,
        do: elem(active, 1),
        else:
          snapshot
          |> Recovery.pending()
          |> then(fn pair -> if pair, do: elem(pair, 1), else: %{} end)

    case entry do
      %{clarification: %{context_revision: asked} = marker} ->
        reply = reply_since(snapshot, asked)
        prefix = get_in(marker, [:input, :request_text]) || caller_before(snapshot, asked)
        OrderDesk.Speech.continue_number(prefix, reply)

      _ ->
        if OrderDesk.Speech.completes_number?(handled, fresh), do: handled <> fresh, else: fresh
    end
  end

  defp clarification_reply(snapshot, recovery, active) do
    case recovery.entry do
      %{clarification: %{context_revision: asked} = marker} ->
        Clarification.reply(marker, reply_since(snapshot, asked), active)

      _ ->
        nil
    end
  end

  defp caller_before(snapshot, revision) do
    snapshot.transcripts
    |> Enum.filter(&(Map.get(&1, :arrival_order, 0) <= revision))
    |> OrderDesk.CallerHistory.latest()
  end

  defp reply_since(snapshot, asked) do
    snapshot.transcripts
    |> Enum.filter(&(Map.get(&1, :arrival_order, 0) > asked))
    |> OrderDesk.CallerHistory.text()
    |> OrderDesk.Speech.join_number_segments()
    |> String.slice(-4_000, 4_000)
  end

  defp handled_input(_snapshot, nil), do: nil

  defp handled_input(_snapshot, {_id, %{input: %{request_text: text}}}) when is_binary(text),
    do: text

  defp handled_input(snapshot, {_id, task}) do
    snapshot.transcripts
    |> Enum.filter(&(Map.get(&1, :arrival_order, 0) <= task.input.user_revision))
    |> OrderDesk.CallerHistory.latest()
    |> String.slice(-4_000, 4_000)
  end

  defp refusal_continuation?(snapshot, {_id, %{input: %{operation: "refuse"}}} = active),
    do:
      OrderDesk.Speech.refusal_continuation?(
        handled_input(snapshot, active),
        latest_input(snapshot, active)
      )

  defp refusal_continuation?(_snapshot, _active), do: false

  defp followup({id, task}, input),
    do: [
      %Decision{
        kind: :start_task,
        anchor_task_id: id,
        expected_anchor_revision: task.revision,
        input: input
      }
    ]

  defp same?(a, b),
    do:
      Map.take(a, [:order, :operation, :instructions]) ==
        Map.take(b, [:order, :operation, :instructions])

  defp start({id, _entry}, input),
    do: [%Decision{kind: :start_task, delegation_id: id, input: input}]

  defp associate({id, task}, {delegation, _entry}),
    do: [
      %Decision{
        kind: :associate_delegation,
        task_id: id,
        expected_task_revision: task.revision,
        delegation_id: delegation
      }
    ]

  defp associate(_active, _pending), do: []

  # Association must target the new revision in a later policy snapshot. A pending
  # delegation may already exist when supersession runs, with no later speech to
  # trigger that snapshot. Use one bounded recheck rather than leave it pending.
  defp association_recheck({id, _entry}, revision) do
    [
      %Decision{
        kind: :wait_for_context,
        delegation_id: id,
        recheck_after_ms: 1,
        recheck_key: "#{revision}:associate"
      }
    ]
  end

  defp association_recheck(nil, _revision), do: []
end
