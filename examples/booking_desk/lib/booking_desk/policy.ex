defmodule BookingDesk.Policy do
  alias BookingDesk.Conversation
  alias BookingDesk.Identity.Extractor
  alias BookingDesk.Recovery

  @moduledoc "Application-owned booking decisions. JEV proposes semantics; code binds operations to current state."
  @behaviour Parlora.ContextPolicy
  alias Parlora.ContextDecision, as: D

  def interpret(snapshot, trigger, opts) do
    guard = Keyword.get(opts, :call_guard)
    verdict = if guard, do: BookingDesk.CallGuard.check(guard, snapshot), else: :allow

    if verdict == :allow do
      interpret_booking(Conversation.attach(snapshot, opts), trigger, opts)
    else
      # Hold existing result delivery as well as new task admission while a
      # caller boundary is unresolved, including during an emergency latch.
      task = latest_task(snapshot)
      pending = snapshot.pending_delegations |> Enum.find(fn {_, d} -> d.status == :pending end)

      target =
        cond do
          task ->
            %D{kind: :wait_for_context, task_id: task.id, expected_task_revision: task.revision}

          pending ->
            %D{kind: :wait_for_context, delegation_id: elem(pending, 0)}

          true ->
            nil
        end

      if target do
        {:ok,
         [
           %{
             target
             | recheck_after_ms: 200,
               recheck_key:
                 "call-guard:#{snapshot.revision}:#{System.unique_integer([:positive])}"
           }
         ]}
      else
        {:ok, []}
      end
    end
  catch
    :exit, _ -> {:error, Parlora.Error.new(:adapter_failed, "Call-boundary check unavailable")}
  end

  defp interpret_booking(snapshot, trigger, opts) do
    user = snapshot.transcripts |> Enum.filter(&(&1.speaker == :user))
    cursor = user |> Enum.map(& &1.arrival_order) |> Enum.max(fn -> 0 end)

    latest =
      latest_task(snapshot)

    pending =
      snapshot.pending_delegations
      |> Enum.filter(fn {_, d} -> d.status == :pending end)
      |> Enum.sort_by(fn {_, d} -> d.received_at_us end)
      |> List.first()

    cond do
      user == [] ->
        {:ok, []}

      latest == nil and pending == nil ->
        observe_request(snapshot, cursor, opts)

      registration_ready?(latest, cursor, snapshot) ->
        resume_search(snapshot, pending, latest, cursor)

      protected_work?(latest, cursor) ->
        {:ok, associate(pending, latest)}

      assistant_speaking?(snapshot, trigger) ->
        target =
          wait_target(pending, latest)

        {:ok,
         [
           %{
             target
             | recheck_after_ms: 200,
               recheck_key: "speech:#{cursor}:#{System.unique_integer([:positive])}"
           }
         ]}

      reminder = BookingDesk.ReminderPolicy.current(snapshot) ->
        reminder_decision(snapshot, reminder, pending, latest, cursor, opts)

      true ->
        interpret_request(snapshot, pending, latest, cursor, opts)
    end
  end

  defp registration_ready?(latest, cursor, snapshot),
    do:
      latest && latest.input.operation in ["lookup", "insurance"] &&
        latest.status == :completed && cursor <= latest.input.cursor && patient(snapshot) != nil

  defp protected_work?(latest, cursor),
    do: caller_consumed?(latest, cursor) || Recovery.pending_write?(latest)

  defp caller_consumed?(latest, cursor), do: latest && cursor <= latest.input.cursor

  defp assistant_speaking?(snapshot, trigger),
    do:
      trigger.kind in [:transcript_updated, :context_wait_expired] &&
        snapshot.provider_speech == :speaking && hd(snapshot.transcripts).speaker == :assistant

  defp request_state(snapshot, latest, cursor) do
    turns =
      BookingDesk.Dialogue.build(snapshot.transcripts,
        after_cursor: if(latest, do: latest.input.cursor),
        with_cursor: true
      )

    dialogue = Enum.map(turns, &Map.take(&1, [:speaker, :text]))
    caller = turns |> Enum.filter(&(&1.speaker == :user)) |> List.last()

    latest_user =
      dialogue |> Enum.filter(&(&1.speaker == :user)) |> List.last() |> Map.fetch!(:text)

    %{
      dialogue: dialogue,
      latest_user: latest_user,
      active:
        if(latest && not Conversation.context(snapshot).identity_changed,
          do:
            Map.drop(latest.input, [
              :name,
              :dob,
              :lookup_request,
              :insurance_request,
              :session,
              :patient
            ])
        ),
      proposal: current_proposal(snapshot),
      insurance: insurance(snapshot),
      conversation: Conversation.decision_context(snapshot),
      retained_identity: Conversation.context(snapshot).identity,
      retained_registration: Conversation.context(snapshot).registration_evidence,
      reminder: BookingDesk.ReminderPolicy.context(snapshot),
      appointment: BookingDesk.ReminderPolicy.appointment(snapshot),
      pending_request: pending_request(snapshot),
      pending_question: if(latest, do: get_in(latest, [:clarification, :message])),
      verified_offers: verified_offers(snapshot),
      dates: BookingDesk.Store.dates(),
      today: "2026-11-02",
      timezone: "America/Denver",
      interpretation_binding: %{
        session_id: snapshot.session_id,
        provider_generation: snapshot.provider_generation,
        caller_cursor: cursor,
        caller_turn: caller.first_cursor,
        application_context:
          Map.drop(snapshot.application_context, [:booking_conversation_frame]),
        tasks:
          Map.new(snapshot.tasks, fn {id, task} ->
            {id, Map.take(task, [:revision, :status, :input, :request_ids, :progress])}
          end)
      }
    }
  end

  defp interpret_request(snapshot, pending, latest, cursor, opts) do
    {snapshot, state, result, demographics} = extract_request(snapshot, latest, cursor, opts)

    context = %{
      snapshot: snapshot,
      pending: pending,
      latest: latest,
      cursor: cursor,
      text: state.latest_user,
      demographics: demographics,
      options: opts
    }

    continue_demographics(context, state, result, opts)
  end

  defp observe_request(snapshot, cursor, opts) do
    if Keyword.get(opts, :conversation), do: extract_request(snapshot, nil, cursor, opts)
    {:ok, []}
  end

  defp extract_request(snapshot, latest, cursor, opts) do
    Process.sleep(Keyword.get(opts, :coalesce_ms, 180))
    state = request_state(snapshot, latest, cursor)
    {snapshot, state} = prepare_registration(snapshot, state, opts)
    result = classify_request(state, opts)
    snapshot = remember_request(snapshot, state, result, latest, cursor, opts)
    state = %{state | conversation: Conversation.decision_context(snapshot)}
    demographics = extract_identity(snapshot, state, result, opts)
    snapshot = Conversation.remember(snapshot, opts, identity: demographics)
    {snapshot, state, result, demographics}
  end

  defp prepare_registration(snapshot, state, opts) do
    snapshot =
      Conversation.remember(snapshot, opts,
        registration_requested: BookingDesk.Identity.requested_in?(state.dialogue)
      )

    snapshot =
      if patient(snapshot) == nil and Conversation.context(snapshot).registration_requested,
        do: Conversation.remember(snapshot, opts, registration_text: state.latest_user),
        else: snapshot

    state = %{
      state
      | conversation: Conversation.decision_context(snapshot),
        retained_registration:
          Enum.reject(
            Conversation.context(snapshot).registration_evidence,
            &(&1 == state.latest_user)
          )
    }

    {snapshot, state}
  end

  defp classify_request(state, opts) do
    judge = Keyword.get(opts, :judge, &BookingDesk.Judgment.classify/1)

    cond do
      command = Recovery.command(state.latest_user) ->
        command

      state.proposal != nil and BookingDesk.Reply.simple(state.latest_user) == :decline ->
        {:ok, %{"intent" => "decline_proposal"}}

      true ->
        judge.(state)
    end
  end

  defp remember_request(snapshot, state, result, latest, cursor, opts) do
    snapshot = Conversation.remember(snapshot, opts, judgment: result)

    snapshot =
      if match?({:ok, %{"intent" => "restart"}}, result) and not Recovery.pending_write?(latest),
        do: Conversation.remember(snapshot, opts, reset: cursor),
        else: snapshot

    snapshot =
      if match?({:ok, %{"intent" => "decline_proposal"}}, result) and state.proposal != nil do
        Conversation.remember(snapshot, opts,
          declined_proposal: state.proposal.id,
          search_declined: %{
            "date" => String.slice(state.proposal.slot, 0, 10),
            "clinician" => state.proposal.clinician_id
          }
        )
      else
        snapshot
      end

    if match?({:ok, %{"intent" => "reminder"}}, result),
      do: resume_reminder(snapshot, state, opts),
      else: snapshot
  end

  defp resume_reminder(snapshot, state, opts) do
    updates =
      if state.proposal,
        do: [reminder_route: :active, declined_proposal: state.proposal.id],
        else: [reminder_route: :active]

    Conversation.remember(snapshot, opts, updates)
  end

  defp extract_identity(snapshot, state, result, opts) do
    control? =
      match?(
        {:ok, %{"intent" => intent}}
        when intent in ["restart", "repeat", "retry", "decline_proposal", "reminder"],
        result
      )

    identity? =
      not control? and
        (match?({:ok, %{"intent" => "lookup"}}, result) or
           (patient(snapshot) == nil and Conversation.context(snapshot).registration_requested))

    extractor = Keyword.get(opts, :identity_extractor, &Extractor.check/1)
    if identity?, do: extractor.(state), else: :not_requested
  end

  defp continue_demographics(%{demographics: :pending} = context, _, _, _),
    do: await_field(context, "identity")

  defp continue_demographics(context, state, result, opts) do
    carrier = extract_carrier(result, state, opts)
    snapshot = Conversation.remember(context.snapshot, opts, carrier: carrier)
    context = %{context | snapshot: snapshot}
    continue_carrier(context, result, carrier)
  end

  defp extract_carrier(result, state, opts) do
    if match?({:ok, %{"intent" => "insurance_update"}}, result) or
         (uncertain_intent?(result) and state.insurance != nil and not state.insurance.confirmed) do
      extract =
        Keyword.get(opts, :insurance_extractor, fn state ->
          Extractor.check(state, BookingDesk.InsuranceExtractor)
        end)

      case extract.(state) do
        {:incomplete, _} = missing -> retained_carrier(result, state, missing)
        other -> other
      end
    else
      :not_requested
    end
  end

  defp retained_carrier({:ok, %{"intent" => "insurance_update"}}, state, missing) do
    case state.conversation.carrier do
      nil -> missing
      carrier -> {:ok, %{carrier: carrier}}
    end
  end

  defp retained_carrier(_, _, missing), do: missing

  defp uncertain_intent?({:incomplete, _, missing}), do: "intent" in missing
  defp uncertain_intent?({:error, :uncertain}), do: true
  defp uncertain_intent?({:ok, %{"intent" => "unclear"}}), do: true
  defp uncertain_intent?(_), do: false

  defp continue_carrier(context, _, :pending), do: await_field(context, "insurance")

  defp continue_carrier(context, result, carrier) do
    result = result |> bind_demographics(context.demographics) |> bind_carrier(carrier)

    interpreted(
      context.snapshot,
      result,
      context.pending,
      context.latest,
      context.cursor,
      context.text,
      context.demographics,
      context.options
    )
  end

  defp bind_demographics({:ok, judgment}, {status, _}) when status in [:ok, :incomplete],
    do: {:ok, Map.put(judgment, "intent", "lookup")}

  defp bind_demographics({:ok, judgment}, {:incomplete, _, _}),
    do: {:ok, Map.put(judgment, "intent", "lookup")}

  defp bind_demographics(result, _), do: result

  defp bind_carrier({:ok, judgment}, {:ok, carrier}),
    do: {:ok, Map.put(judgment, "new_carrier", carrier.carrier)}

  defp bind_carrier(_, {:error, _}), do: {:error, :unavailable}
  defp bind_carrier(result, _), do: result

  defp await_field(context, field) do
    target = wait_target(context.pending, context.latest)

    {:ok,
     [
       %{
         target
         | recheck_after_ms: 200,
           recheck_key: "#{field}:#{context.cursor}:#{System.unique_integer([:positive])}"
       }
     ]}
  end

  defp reminder_decision(snapshot, reminder, pending, latest, cursor, opts) do
    # Terminal reminder state cannot create another write from a social reply.
    if reminder.status in ["scheduled", "declined"] do
      {:ok, associate(pending, latest)}
    else
      # Coalesce complete caller turns, including a trailing correction or refusal.
      key = "reminder:#{cursor}"

      if match?(%{context_wait: %{expired?: true, recheck_key: ^key}}, latest) do
        apply_reminder(snapshot, reminder, pending, latest, cursor, opts)
      else
        {:ok,
         [
           %D{
             kind: :wait_for_context,
             task_id: latest.id,
             expected_task_revision: latest.revision,
             recheck_after_ms: 1_500,
             recheck_key: key
           }
         ]}
      end
    end
  end

  defp apply_reminder(snapshot, reminder, pending, latest, cursor, opts) do
    case BookingDesk.ReminderPolicy.interpret(snapshot, reminder, opts) do
      :appointment ->
        snapshot = Conversation.remember(snapshot, opts, reminder_route: :suspended)
        interpret_request(snapshot, pending, latest, cursor, opts)

      {:input, fields} ->
        input =
          base(snapshot, cursor)
          |> Map.merge(fields)
          |> Map.merge(%{
            booking_request: reminder.appointment,
            reminder_revision: reminder.request_id
          })

        {:ok, start(pending, latest, input)}

      {:clarify, message} ->
        clarify(cursor, pending, latest, message)

      :associate ->
        {:ok, associate(pending, latest)}

      :wait ->
        {:ok,
         [
           %D{
             kind: :wait_for_context,
             task_id: latest.id,
             expected_task_revision: latest.revision,
             recheck_after_ms: 200,
             recheck_key: "reminder-extract:#{cursor}:#{System.unique_integer([:positive])}"
           }
         ]}
    end
  end

  defp interpreted(
         snapshot,
         _result,
         pending,
         latest,
         cursor,
         latest_user,
         {:error, _} = failure,
         opts
       ) do
    decide(
      snapshot,
      {:ok, %{"intent" => "lookup"}},
      pending,
      latest,
      cursor,
      latest_user,
      failure,
      opts
    )
  end

  defp interpreted(snapshot, result, pending, latest, cursor, latest_user, demographics, opts) do
    result = registration_interpretation(snapshot, result, demographics)

    uncertain = needs_clarification?(latest, result, latest_user, demographics, opts)

    # A semantic approval can precede its complete spoken wording ("Yeah, go ...").
    # Keep the literal consent check, but give later fragments the same bounded
    # context window as uncertain interpretations before asking a clarification.

    if uncertain && (latest == nil || latest.input.operation != "confirm") do
      entry = latest || (pending && elem(pending, 1))
      key = "uncertain:#{cursor}"

      if match?(%{context_wait: %{expired?: true, recheck_key: ^key}}, entry) do
        decide(snapshot, result, pending, latest, cursor, latest_user, demographics, opts)
      else
        target =
          wait_target(pending, latest)

        {:ok, [%{target | recheck_after_ms: 1_500, recheck_key: key}]}
      end
    else
      decide(snapshot, result, pending, latest, cursor, latest_user, demographics, opts)
    end
  end

  defp needs_clarification?(latest, result, latest_user, demographics, opts) do
    uncertain_result?(result) or incomplete_identity?(demographics) or
      partial_approval?(latest, result, latest_user) or
      settle_approval?(latest, result, opts)
  end

  defp settle_approval?(latest, result, opts),
    do:
      match?(%{input: %{operation: "propose"}}, latest) and
        match?({:ok, %{"intent" => "confirm"}}, result) and
        Keyword.get(opts, :settle_confirm_ms, 1_500) > 0

  defp uncertain_result?({:ok, %{"intent" => intent}}),
    do: intent in ["insurance_same", "insurance_changed", "unclear"]

  defp uncertain_result?({:ok, _}), do: false
  defp uncertain_result?(_), do: true

  defp incomplete_identity?({:incomplete, _}), do: true
  defp incomplete_identity?({:incomplete, _, _}), do: true
  defp incomplete_identity?(_), do: false

  defp registration_interpretation(snapshot, result, demographics) do
    if incomplete_identity?(demographics) and
         Conversation.context(snapshot).registration_requested,
       do: {:ok, %{"intent" => "lookup"}},
       else: result
  end

  defp partial_approval?(
         %{input: %{operation: "propose"}},
         {:ok, %{"intent" => "confirm"}},
         text
       ),
       do: not explicit_confirmation?(text)

  defp partial_approval?(_, _, _), do: false

  def decide(
        snapshot,
        result,
        pending,
        latest,
        cursor,
        text,
        demographics \\ :not_requested,
        opts \\ []
      ) do
    if Recovery.pending_write?(latest) do
      {:ok, associate(pending, latest)}
    else
      {snapshot, result} = search_reply(snapshot, latest, cursor, text, result, opts)
      dispatch_decision(snapshot, result, pending, latest, cursor, text, demographics)
    end
  end

  defp dispatch_decision(snapshot, result, pending, latest, cursor, text, demographics) do
    case result do
      {:incomplete, judgment, missing} ->
        incomplete_decision(snapshot, judgment, missing, pending, latest, cursor, text)

      {:ok, %{"intent" => intent} = judgment} ->
        context = %{
          snapshot: snapshot,
          pending: pending,
          latest: latest,
          cursor: cursor,
          text: text,
          demographics: demographics
        }

        decide_intent(intent, judgment, context)

      {:error, :unavailable} ->
        clarify(
          cursor,
          pending,
          latest,
          "I'm having trouble checking that request right now. Please try again in a moment. Nothing has been changed."
        )

      _ ->
        clarify_booking(snapshot, cursor, pending, latest, %{}, ["intent"])
    end
  end

  defp incomplete_decision(snapshot, judgment, missing, pending, latest, cursor, text) do
    if judgment["intent"] in ["choose_slot", "reschedule"] do
      decide_intent(judgment["intent"], judgment, %{
        snapshot: snapshot,
        pending: pending,
        latest: latest,
        cursor: cursor,
        text: text,
        demographics: :not_requested
      })
    else
      clarify_booking(snapshot, cursor, pending, latest, judgment, missing)
    end
  end

  defp search_reply(snapshot, latest, cursor, text, result, opts) do
    if match?(
         {:ok, %{"intent" => intent}}
         when intent not in ["none", "progress", "unclear", "confirm"],
         result
       ),
       do: {snapshot, result},
       else: resolve_search_reply(snapshot, latest, cursor, text, result, opts)
  end

  defp resolve_search_reply(snapshot, latest, cursor, text, result, opts) do
    case {identity(snapshot), insurance(snapshot)} do
      {%{lookup_request: lookup}, %{confirmed: true}} ->
        case BookingDesk.SearchClarification.reply(
               snapshot,
               latest,
               lookup,
               pending_request(snapshot),
               cursor,
               text,
               opts
             ) do
          {:ok, _} = reply ->
            {snapshot, reply}

          {:decline, _} ->
            preferences = %{"date" => latest.input.date, "clinician" => latest.input.clinician}
            snapshot = Conversation.remember(snapshot, opts, search_declined: preferences)
            {snapshot, {:ok, %{"intent" => "decline_search"}}}

          {:repeat, _} ->
            {snapshot, {:ok, %{"intent" => "repeat"}}}

          :unresolved ->
            {snapshot, result}
        end

      _ ->
        {snapshot, result}
    end
  end

  defp decide_intent("reminder", _, context) do
    case BookingDesk.ReminderPolicy.state(context.snapshot) do
      nil ->
        clarify(
          context.cursor,
          context.pending,
          context.latest,
          "Let's finish selecting and confirming an appointment first. What appointment help do you need?"
        )

      %{status: status} when status in ["scheduled", "declined"] ->
        clarify(
          context.cursor,
          context.pending,
          context.latest,
          "The reminder is already #{status}. Your appointment remains booked."
        )

      reminder ->
        clarify(
          context.cursor,
          context.pending,
          context.latest,
          BookingDesk.ReminderPolicy.question(reminder)
        )
    end
  end

  defp decide_intent("decline_proposal", _, context) do
    clarify(
      context.cursor,
      context.pending,
      context.latest,
      "I haven't accepted that proposal or changed your appointment. Would you like to check a different date or time?",
      %{
        booking_request: pending_request(context.snapshot),
        lookup_request: identity(context.snapshot).lookup_request,
        unresolved_intent: false
      }
    )
  end

  defp decide_intent("decline_search", _, context) do
    lookup = identity(context.snapshot)

    clarify(
      context.cursor,
      context.pending,
      context.latest,
      "I haven't changed that search. Which date would you like to check?",
      %{
        booking_request: pending_request(context.snapshot),
        lookup_request: lookup.lookup_request,
        unresolved_intent: false
      }
    )
  end

  defp decide_intent("restart", _, context) do
    if Recovery.pending_write?(context.latest),
      do: {:ok, associate(context.pending, context.latest)},
      else:
        clarify(
          context.cursor,
          context.pending,
          context.latest,
          "Let's start a new request. Completed appointments remain unchanged. Could I have your full name and date of birth?",
          %{booking_request: %{}, lookup_request: nil}
        )
  end

  defp decide_intent("repeat", _, context) do
    if Recovery.pending_write?(context.latest) or
         (match?(%{status: :submitted, input: %{operation: "availability"}}, context.latest) and
            not unresolved_search?(context.snapshot, context.latest)) do
      {:ok, associate(context.pending, context.latest)}
    else
      state = request_state(context.snapshot, context.latest, context.cursor)

      clarify(
        context.cursor,
        context.pending,
        context.latest,
        Recovery.question(state, context.latest),
        if(context.latest, do: get_in(context.latest, [:clarification, :input]) || %{}, else: %{})
      )
    end
  end

  defp decide_intent(
         "retry",
         _,
         %{latest: %{status: status, input: %{operation: "availability"}} = latest} = context
       )
       when status in [:failed, :cancelled, :completed] do
    decide_intent(
      "availability",
      %{"date" => latest.input.date, "clinician" => latest.input.clinician},
      context
    )
  end

  defp decide_intent("retry", _, %{latest: %{input: %{operation: "confirm"}} = latest} = context),
    do: {:ok, associate(context.pending, latest)}

  defp decide_intent("retry", _, context),
    do:
      clarify(
        context.cursor,
        context.pending,
        context.latest,
        "Which date and doctor would you like to check? A booking that was already submitted will not be retried."
      )

  defp decide_intent(intent, _judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor
       })
       when intent in ["none", "progress"] do
    if unresolved_search?(snapshot, latest),
      do: clarify_booking(snapshot, cursor, pending, latest, %{}, ["intent"]),
      else: {:ok, associate(pending, latest)}
  end

  defp decide_intent(intent, judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor,
         text: text
       })
       when intent in ["insurance_same", "insurance_changed", "insurance_update"] do
    current = insurance(snapshot)

    cond do
      current == nil ->
        clarify(
          cursor,
          pending,
          latest,
          "Could I have your full name and date of birth so I can find your record?"
        )

      insurance_current?(intent, current) ->
        {:ok, associate(pending, latest)}

      insurance_refused?(intent, text) ->
        clarify(cursor, pending, latest, BookingDesk.Insurance.question(current))

      intent == "insurance_update" and
          not BookingDesk.Insurance.valid_carrier?(judgment["new_carrier"]) ->
        clarify(
          cursor,
          pending,
          latest,
          "What insurance company or plan do you have now?"
        )

      true ->
        response =
          %{
            "insurance_same" => "unchanged",
            "insurance_changed" => "changed",
            "insurance_update" => "updated"
          }[intent]

        carrier =
          if response == "updated", do: judgment["new_carrier"], else: current.carrier

        preferences = registration_preferences(snapshot, judgment, latest)

        input =
          base(snapshot, cursor)
          |> Map.merge(%{
            operation: "insurance",
            response: response,
            carrier: carrier,
            insurance_revision: current.revision,
            date: preferences.date,
            clinician: preferences.clinician
          })

        {:ok, start(pending, latest, input)}
    end
  end

  defp decide_intent(intent, judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor
       })
       when intent in ["availability", "replace_search", "additional_search"] do
    date = judgment["date"]
    clinician = clinician_preference(judgment, latest)

    cond do
      patient(snapshot) == nil ->
        clarify(
          cursor,
          pending,
          latest,
          "Could I have your full name and date of birth so I can find your record?"
        )

      not insurance(snapshot).confirmed ->
        clarify(
          cursor,
          pending,
          latest,
          BookingDesk.Insurance.question(insurance(snapshot))
        )

      clinician not in ["lee", "patel", "any"] ->
        clarify_booking(
          snapshot,
          cursor,
          pending,
          latest,
          judgment,
          ["clinician"]
        )

      date in BookingDesk.Store.dates() ->
        input =
          base(snapshot, cursor)
          |> Map.merge(%{
            operation: "availability",
            date: date,
            clinician: clinician,
            search_intent: intent
          })

        {:ok, availability_decisions(intent, pending, latest, input)}

      true ->
        clarify_booking(
          snapshot,
          cursor,
          pending,
          latest,
          judgment,
          ["date"]
        )
    end
  end

  defp decide_intent("lookup", judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor,
         demographics: demographics
       }) do
    case demographics do
      {:ok, demographics} ->
        preferences = registration_preferences(snapshot, judgment, latest)

        input =
          Map.merge(demographics, %{
            operation: "lookup",
            session: snapshot.session_id,
            cursor: cursor,
            date: preferences.date,
            clinician: preferences.clinician
          })

        {:ok, start(pending, latest, input)}

      {:error, :invalid_extraction} ->
        clarify(
          cursor,
          pending,
          latest,
          "I couldn't verify the name and date of birth I heard. Could you say your full name, then your birth month, day, and year?"
        )

      {:error, _} ->
        clarify(
          cursor,
          pending,
          latest,
          "I'm having trouble reading the patient details right now. Please try again in a moment. No appointment has been changed."
        )

      missing ->
        clarify(cursor, pending, latest, identity_question(missing))
    end
  end

  defp decide_intent(intent, judgment, %{snapshot: snapshot} = context)
       when intent in ["choose_slot", "reschedule", "cancel"] do
    cond do
      patient(snapshot) == nil ->
        clarify(
          context.cursor,
          context.pending,
          context.latest,
          "Could I have your full name and date of birth so I can find your record?"
        )

      intent != "cancel" and not insurance(snapshot).confirmed ->
        clarify(
          context.cursor,
          context.pending,
          context.latest,
          BookingDesk.Insurance.question(insurance(snapshot))
        )

      intent != "cancel" and judgment["date"] not in BookingDesk.Store.dates() ->
        clarify_booking(snapshot, context.cursor, context.pending, context.latest, judgment, [
          "date"
        ])

      true ->
        appointment_intent(intent, judgment, context)
    end
  end

  defp decide_intent("confirm", _judgment, %{
         pending: pending,
         latest: %{input: %{operation: "confirm"}} = latest
       }) do
    {:ok, associate(pending, latest)}
  end

  defp decide_intent("confirm", judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor,
         text: text
       }) do
    proposal = current_proposal(snapshot)

    if proposal && explicit_confirmation?(text) &&
         confirmation_matches?(proposal, judgment) &&
         retained_preferences_match?(snapshot, proposal, judgment) do
      input =
        Map.merge(base(snapshot, cursor), %{
          operation: "confirm",
          proposal: proposal.id,
          revision: proposal.revision
        })

      {:ok, start(pending, latest, input)}
    else
      clarify(
        cursor,
        pending,
        latest,
        "Please choose the exact appointment first, then explicitly confirm that proposal. Nothing has been changed."
      )
    end
  end

  defp decide_intent(_intent, _judgment, %{
         pending: pending,
         latest: %{input: %{operation: "confirm"}} = latest
       })
       when latest.status not in [:completed, :failed, :cancelled] do
    {:ok, associate(pending, latest)}
  end

  defp decide_intent(_, judgment, %{
         snapshot: snapshot,
         cursor: cursor,
         pending: pending,
         latest: latest
       }) do
    clarify_booking(snapshot, cursor, pending, latest, judgment, ["intent"])
  end

  defp insurance_current?(intent, current), do: intent == "insurance_same" and current.confirmed

  defp insurance_refused?(intent, text),
    do: intent == "insurance_same" and not BookingDesk.Consent.unconditional?(text)

  defp appointment_intent(intent, judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor
       })
       when intent in ["choose_slot", "reschedule"] do
    date = judgment["date"]
    time = judgment["time"]

    verified = completed_search(snapshot, date, judgment["clinician"])
    clinician = clinician_preference(judgment, verified)
    candidates = slot_candidates(snapshot, verified, date, time, clinician)

    if verified == nil and date in BookingDesk.Store.dates() do
      decide_intent("availability", judgment, %{
        snapshot: snapshot,
        pending: pending,
        latest: latest,
        cursor: cursor
      })
    else
      choose_candidate(candidates, snapshot, pending, latest, cursor, intent, verified)
    end
  end

  defp appointment_intent("cancel", _judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor
       }) do
    input =
      Map.merge(base(snapshot, cursor), %{
        operation: "propose",
        change: "cancel",
        slot: "",
        appointment: appointment_target(snapshot),
        revision: cursor
      })

    {:ok, start(pending, latest, input)}
  end

  defp choose_candidate(candidates, snapshot, pending, latest, cursor, intent, verified) do
    case candidates do
      [slot] ->
        propose_slot(snapshot, pending, latest, cursor, intent, slot, verified)

      [_, _ | _] ->
        clarify(
          cursor,
          pending,
          latest,
          "More than one doctor has that time. Which doctor would you prefer?"
        )

      _ ->
        clarify(
          cursor,
          pending,
          latest,
          "Please choose a doctor and an exact time from the availability we checked. Nothing has been booked."
        )
    end
  end

  defp unresolved_search?(snapshot, %{input: %{operation: "availability"}} = task) do
    request = pending_request(snapshot)

    changed? =
      Enum.any?([{"date", :date}, {"clinician", :clinician}], fn {key, field} ->
        request[key] != nil and request[key] != Map.get(task.input, field)
      end)

    unresolved? =
      case Map.get(task, :clarification) do
        %{input: %{booking_request: _, unresolved_intent: true, lookup_request: lookup}} ->
          match?(%{lookup_request: ^lookup}, identity(snapshot))

        _ ->
          false
      end

    changed? or unresolved?
  end

  defp unresolved_search?(_, _), do: false

  defp identity_question({:incomplete, missing, _}), do: identity_question({:incomplete, missing})

  defp identity_question({:incomplete, [:name]}),
    do: "Could I have your full name so I can find your record?"

  defp identity_question({:incomplete, [:dob]}),
    do: "Could I have your complete date of birth, including the year?"

  defp identity_question(_),
    do: "Could you clarify your full name and date of birth so I can find your record?"

  defp completed_search(snapshot, date, clinician) do
    snapshot
    |> active_searches()
    |> Enum.filter(&(&1.input.date == date and searched_clinician?(&1.input, clinician)))
    |> Enum.max_by(& &1.input.cursor, fn -> nil end)
  end

  defp searched_clinician?(input, clinician) when clinician in ~w(lee patel),
    do: Map.get(input, :clinician) in [clinician, "any"]

  defp searched_clinician?(_, _), do: true

  defp active_searches(snapshot) do
    snapshot.tasks
    |> Map.values()
    |> Enum.filter(&(&1.input.operation == "availability"))
    |> Enum.sort_by(& &1.input.cursor, :desc)
    |> Enum.reduce_while([], fn task, acc ->
      if Map.get(task.input, :search_intent) == "additional_search",
        do: {:cont, [task | acc]},
        else: {:halt, [task | acc]}
    end)
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.reverse()
  end

  defp slot_candidates(snapshot, verified, date, time, clinician) do
    if verified && patient(snapshot) do
      BookingDesk.Store.offered(
        patient(snapshot),
        verified.input.cursor,
        identity(snapshot).lookup_request
      )
      |> Enum.filter(&matching_slot?(&1, date, time, clinician))
    else
      []
    end
  end

  defp matching_slot?(slot, date, time, clinician),
    do:
      slot.date == date and slot.time == time and
        (clinician in [nil, "unknown", "any"] or slot.clinician == clinician)

  defp propose_slot(snapshot, pending, latest, cursor, intent, slot, verified) do
    input =
      Map.merge(base(snapshot, cursor), %{
        operation: "propose",
        change: if(intent == "reschedule", do: "reschedule", else: "book"),
        slot: slot.id,
        clinician: slot.clinician,
        appointment: appointment_target(snapshot),
        revision: cursor,
        search_cursor: verified.input.cursor
      })

    if latest && latest.input.operation == "propose" &&
         latest.input.slot == input.slot && latest.input.change == input.change &&
         latest.status not in [:failed, :cancelled] &&
         (latest.status != :completed || current_proposal(snapshot) != nil),
       do: {:ok, associate(pending, latest)},
       else: {:ok, start(pending, latest, input)}
  end

  defp availability_decisions(intent, pending, latest, input) do
    cond do
      same_search?(latest, input) and latest.status in [:completed, :failed, :cancelled] and
          input.cursor > latest.input.cursor ->
        replace_search(pending, latest, input)

      same_search?(latest, input) and
          match?(%{input: %{unresolved_intent: true}}, Map.get(latest, :clarification)) ->
        replace_search(pending, latest, input)

      same_search?(latest, input) ->
        associate(pending, latest)

      replacement_search?(intent, latest) ->
        replace_search(pending, latest, input)

      true ->
        start(pending, latest, input)
    end
  end

  defp same_search?(latest, input),
    do:
      not is_nil(latest) and latest.input.operation == "availability" and
        latest.input.date == input.date and Map.get(latest.input, :clinician) == input.clinician

  defp replacement_search?(intent, latest),
    do:
      intent in ["availability", "replace_search"] && latest &&
        latest.input.operation == "availability"

  defp replace_search(nil, latest, input), do: wait_for_delegation(latest, input)

  defp replace_search(pending, latest, input),
    do: [
      %D{
        kind: :supersede_task,
        task_id: latest.id,
        expected_task_revision: latest.revision,
        delegation_id: delegation(pending),
        input: input
      }
    ]

  defp clarify_booking(snapshot, cursor, pending, latest, judgment, missing) do
    # Only confident, validated preferences survive a clarification. This is
    # conversation state, not task admission or permission to submit a booking.
    request =
      Map.merge(booking_preferences(pending_request(snapshot)), booking_preferences(judgment))

    request = if "intent" in missing, do: Map.delete(request, "intent"), else: request
    lookup = identity(snapshot)

    input = %{
      booking_request: request,
      unresolved_intent: "intent" in missing,
      lookup_request: if(lookup, do: lookup.lookup_request)
    }

    offer =
      if "intent" in missing and match?(%{confirmed: true}, insurance(snapshot)),
        do: BookingDesk.SearchClarification.offer(snapshot, latest, request, cursor)

    case offer do
      {question, action} ->
        clarify(cursor, pending, latest, question, Map.put(input, :search_clarification, action))

      _ ->
        clarify(
          cursor,
          pending,
          latest,
          clarification_question(snapshot, request, missing),
          input
        )
    end
  end

  defp booking_preferences(judgment) do
    Conversation.preferences(judgment)
  end

  defp clarification_question(snapshot, request, missing) do
    carrier = Conversation.context(snapshot).carrier
    current = insurance(snapshot)
    proposal = current_proposal(snapshot)

    cond do
      proposal != nil and proposal_preferences_match?(proposal, request) ->
        Recovery.proposal_question(proposal)

      current != nil and not current.confirmed and carrier != nil ->
        "I've kept #{carrier} as the insurance company you supplied. Should I update that information? Your appointment has not been changed."

      current != nil and not current.confirmed ->
        BookingDesk.Insurance.question(current)

      true ->
        booking_question(request, missing)
    end
  end

  defp proposal_preferences_match?(%{change: "cancel"}, _), do: true

  defp proposal_preferences_match?(proposal, request) do
    expected = %{
      "date" => String.slice(proposal.slot, 0, 10),
      "time" => String.slice(proposal.slot, 11, 5),
      "clinician" => proposal.clinician_id
    }

    Enum.all?(Map.take(request, ["date", "time", "clinician"]), fn {key, value} ->
      value == "any" or expected[key] == value
    end)
  end

  defp booking_question(request, missing) do
    cond do
      "date" in missing ->
        case request["clinician"] do
          "lee" -> "What date would you like to see Dr. Lee?"
          "patel" -> "What date would you like to see Dr. Patel?"
          _ -> "Which date would you like to check? Please include the month and day."
        end

      "time" in missing ->
        "Which exact time would you like from the options we checked?"

      "clinician" in missing ->
        "Do you have a particular doctor in mind, or is any available doctor okay?"

      true ->
        intent_question(request)
    end
  end

  defp intent_question(request) do
    preferences =
      ["date", "clinician", "time"]
      |> Enum.map(&preference_label(&1, request[&1]))
      |> Enum.reject(&is_nil/1)

    if preferences == [] do
      "Could you clarify what appointment help you need? Nothing has been changed."
    else
      "I've kept your appointment preferences: #{Enum.join(preferences, ", ")}. " <>
        "Would you like to check availability, change the search, or choose a time we already checked? Nothing has been booked."
    end
  end

  defp preference_label(_, nil), do: nil

  defp preference_label("date", value),
    do: value |> Date.from_iso8601!() |> Calendar.strftime("%B %-d, %Y")

  defp preference_label(_, value),
    do:
      %{
        "lee" => "Dr. Lee",
        "patel" => "Dr. Patel",
        "any" => "any available doctor",
        "10:15" => "10:15 AM",
        "14:00" => "2:00 PM"
      }[value]

  defp pending_request(snapshot) do
    task = latest_task(snapshot)

    clarification =
      if task do
        Map.get(task, :clarification)
      else
        snapshot.pending_delegations
        |> Map.values()
        |> Enum.map(&Map.get(&1, :clarification))
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&Map.get(&1, :context_revision, 0), fn -> nil end)
      end

    lookup = identity(snapshot)
    expected = if lookup, do: lookup.lookup_request

    case clarification do
      %{input: %{booking_request: request, lookup_request: ^expected}} ->
        Map.merge(request, Conversation.context(snapshot).preferences)

      _ ->
        Conversation.context(snapshot).preferences
    end
  end

  defp verified_offers(snapshot) do
    if unresolved_search?(snapshot, latest_task(snapshot)),
      do: [],
      else: current_offers(snapshot)
  end

  defp current_offers(snapshot) do
    case {identity(snapshot), insurance(snapshot)} do
      {%{patient: patient, lookup_request: lookup}, %{confirmed: true, insurance_request: proof}} ->
        snapshot
        |> active_searches()
        |> Enum.filter(&current_search?(&1, patient, lookup, proof))
        |> Enum.uniq_by(&{&1.input.date, &1.input.clinician})
        |> Enum.flat_map(&BookingDesk.Store.offered(patient, &1.input.cursor, lookup))
        |> Enum.map(&Map.take(&1, [:date, :time, :clinician]))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp current_search?(task, patient, lookup, proof) do
    task.status == :completed and task.input.operation == "availability" and
      Map.get(task.input, :patient) == patient and Map.get(task.input, :lookup_request) == lookup and
      Map.get(task.input, :insurance_request) == proof
  end

  def current_proposal(snapshot, store \\ BookingDesk.Store) do
    case {latest_task(snapshot), identity(snapshot, store)} do
      {%{
         status: :completed,
         input: %{operation: "propose", revision: revision} = input,
         request_ids: [id | _]
       }, %{patient: patient, lookup_request: lookup}} ->
        if input.patient == patient and input.lookup_request == lookup and
             Conversation.context(snapshot).declined_proposal != id do
          stored_proposal(input, id, patient, lookup, revision, store)
        end

      _ ->
        nil
    end
  end

  defp stored_proposal(input, id, patient, lookup, revision, store) do
    case BookingDesk.Store.readback_proposal(patient, id, revision, store) do
      %{lookup_request: ^lookup} = proposal ->
        if Map.get(input, :change) == "cancel" or proposal.slot == input.slot,
          do: Map.take(proposal, [:id, :change, :slot, :revision, :clinician_id])

      _ ->
        nil
    end
  end

  defp confirmation_matches?(%{change: "cancel"}, _judgment), do: true

  defp confirmation_matches?(proposal, judgment) do
    judgment["date"] == String.slice(proposal.slot, 0, 10) &&
      judgment["time"] == String.slice(proposal.slot, 11, 5) &&
      judgment["clinician"] == proposal.clinician_id
  end

  defp retained_preferences_match?(snapshot, proposal, judgment) do
    preferences =
      snapshot |> pending_request() |> booking_preferences() |> Map.drop(["intent"])

    preferences =
      if preferences["clinician"] == "any",
        do: Map.delete(preferences, "clinician"),
        else: preferences

    confirmation_matches?(proposal, Map.merge(judgment, preferences))
  end

  defp explicit_confirmation?(text) do
    text = String.replace(text, "’", "'")

    Regex.match?(
      ~r/\b(yes|confirm|go ahead|please book|please cancel|please reschedule)\b/i,
      text
    ) &&
      BookingDesk.Consent.unconditional?(text)
  end

  def identity(snapshot, store \\ BookingDesk.Store) do
    if Conversation.context(snapshot).identity_changed,
      do: nil,
      else: matched_identity(snapshot, store)
  end

  defp matched_identity(snapshot, store) do
    lookup =
      snapshot.tasks
      |> Map.values()
      |> Enum.filter(&(&1.input.operation == "lookup"))
      |> Enum.max_by(& &1.input.cursor, fn -> nil end)

    request =
      case lookup do
        %{status: :completed, request_ids: [id | _]} -> id
        nil -> Map.get(snapshot.application_context, :lookup_request)
        _ -> nil
      end

    if is_binary(request) do
      case BookingDesk.Store.identity(request, snapshot.session_id, store) do
        patient when is_binary(patient) ->
          current_insurance = BookingDesk.Store.insurance(request, snapshot.session_id, store)

          %{
            patient: patient,
            lookup_request: request,
            session: snapshot.session_id,
            insurance_request: current_insurance.insurance_request
          }

        _ ->
          nil
      end
    end
  end

  def insurance(snapshot, store \\ BookingDesk.Store) do
    case identity(snapshot, store) do
      %{lookup_request: lookup, session: session} ->
        BookingDesk.Store.insurance(lookup, session, store)

      _ ->
        nil
    end
  end

  def patient(snapshot, store \\ BookingDesk.Store) do
    case identity(snapshot, store) do
      %{patient: patient} -> patient
      _ -> nil
    end
  end

  defp appointment_target(snapshot) do
    case BookingDesk.ReminderPolicy.appointment(snapshot) do
      %{appointment: id, status: "booked"} -> id
      _ -> "appt_existing"
    end
  end

  defp base(snapshot, cursor), do: Map.put(identity(snapshot) || %{}, :cursor, cursor)

  defp latest_task(snapshot),
    do:
      snapshot.tasks
      |> Map.values()
      |> Enum.max_by(
        fn t ->
          {Map.get(t.input, :cursor, 0),
           Map.get(
             %{
               "lookup" => 0,
               "insurance" => 1,
               "availability" => 2,
               "propose" => 3,
               "confirm" => 4
             },
             t.input.operation,
             0
           )}
        end,
        fn -> nil end
      )

  defp clinician_preference(judgment, latest) do
    case judgment["clinician"] do
      value when value in ["lee", "patel", "any"] -> value
      _ -> if latest, do: Map.get(latest.input, :clinician), else: nil
    end
  end

  defp resume_search(snapshot, pending, lookup, cursor) do
    if Conversation.context(snapshot).goal == "cancel" do
      input =
        base(snapshot, cursor)
        |> Map.merge(%{
          operation: "propose",
          change: "cancel",
          slot: "",
          appointment: appointment_target(snapshot),
          revision: cursor
        })

      start_followup(pending, lookup, input)
    else
      resume_registration_search(snapshot, pending, lookup, cursor)
    end
  end

  defp resume_registration_search(snapshot, pending, lookup, cursor) do
    preferences = registration_preferences(snapshot, %{}, lookup)
    date = preferences.date
    clinician = preferences.clinician

    cond do
      not insurance(snapshot).confirmed ->
        # Deliver the matched lookup / changed-insurance result. Its database-derived
        # summary asks the registration question once; do not start calendar work.
        {:ok, associate(pending, lookup)}

      clinician not in ["lee", "patel", "any"] ->
        clarify(
          cursor,
          pending,
          lookup,
          "Do you have a particular doctor in mind, or is any available doctor okay?"
        )

      date not in BookingDesk.Store.dates() ->
        clarify(cursor, pending, lookup, "Which date would you like to check?")

      true ->
        input =
          Map.merge(base(snapshot, cursor), %{
            operation: "availability",
            date: date,
            clinician: clinician
          })

        start_followup(pending, lookup, input)
    end
  end

  defp start_followup(nil, lookup, input),
    do:
      {:ok,
       [
         %D{
           kind: :start_task,
           anchor_task_id: lookup.id,
           expected_anchor_revision: lookup.revision,
           input: input
         }
       ]}

  defp start_followup(pending, lookup, input), do: {:ok, start(pending, lookup, input)}

  defp registration_preferences(snapshot, judgment, latest) do
    preferences = Map.merge(pending_request(snapshot), booking_preferences(judgment))
    latest = if Conversation.context(snapshot).identity_changed, do: nil, else: latest

    %{
      date: preferences["date"] || (latest && Map.get(latest.input, :date)),
      clinician: preferences["clinician"] || clinician_preference(judgment, latest)
    }
  end

  defp wait_target(_pending, latest) when not is_nil(latest),
    do: %D{kind: :wait_for_context, task_id: latest.id, expected_task_revision: latest.revision}

  defp wait_target(pending, nil),
    do: %D{kind: :wait_for_context, delegation_id: delegation(pending)}

  defp delegation(nil), do: nil
  defp delegation({id, _}), do: id

  defp start({id, _}, _latest, input),
    do: [%D{kind: :start_task, delegation_id: id, input: input}]

  defp start(nil, nil, _input), do: []

  defp start(nil, latest, input), do: wait_for_delegation(latest, input)

  # Hold old results as soon as context changes, but admit new execution only
  # once the speech provider has opened a correlated application delegation.
  defp wait_for_delegation(latest, input) do
    [
      %D{
        kind: :wait_for_context,
        task_id: latest.id,
        expected_task_revision: latest.revision,
        recheck_after_ms: 200,
        recheck_key: "delegation:#{input.cursor}:#{System.unique_integer([:positive])}"
      }
    ]
  end

  defp associate(nil, _), do: []
  defp associate(_, nil), do: []

  defp associate({id, _}, task),
    do: [
      %D{
        kind: :associate_delegation,
        delegation_id: id,
        task_id: task.id,
        expected_task_revision: task.revision
      }
    ]

  defp clarify(cursor, pending, task, message, input \\ %{})

  defp clarify(_cursor, nil, nil, _message, _input), do: {:ok, []}

  defp clarify(cursor, pending, task, message, input) do
    target =
      if task,
        do: %D{
          kind: :request_clarification,
          task_id: task.id,
          expected_task_revision: task.revision,
          delegation_id: delegation(pending)
        },
        else: %D{kind: :request_clarification, delegation_id: delegation(pending)}

    {:ok,
     [
       %{
         target
         | input: input,
           message: message,
           clarification_key: clarification_key(cursor, message, input)
       }
     ]}
  end

  defp clarification_key(cursor, message, input) do
    digest =
      {message, input}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "caller:#{cursor}:#{digest}"
  end
end
