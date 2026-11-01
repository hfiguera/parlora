defmodule BookingDesk.Policy do
  alias BookingDesk.Identity.Extractor

  @moduledoc "Application-owned booking decisions. JEV proposes semantics; code binds operations to current state."
  @behaviour Parlora.ContextPolicy
  alias Parlora.ContextDecision, as: D

  def interpret(snapshot, trigger, opts) do
    guard = Keyword.get(opts, :call_guard)
    verdict = if guard, do: BookingDesk.CallGuard.check(guard, snapshot), else: :allow

    if verdict == :allow do
      interpret_booking(snapshot, trigger, opts)
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
      user == [] or (latest == nil and pending == nil) ->
        {:ok, []}

      registration_ready?(latest, cursor, snapshot) ->
        resume_search(snapshot, pending, latest, cursor)

      caller_consumed?(latest, cursor) ->
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

  defp caller_consumed?(latest, cursor), do: latest && cursor <= latest.input.cursor

  defp assistant_speaking?(snapshot, trigger),
    do:
      trigger.kind in [:transcript_updated, :context_wait_expired] &&
        snapshot.provider_speech == :speaking && hd(snapshot.transcripts).speaker == :assistant

  defp request_state(snapshot, latest, cursor) do
    dialogue =
      BookingDesk.Dialogue.build(snapshot.transcripts,
        after_cursor: if(latest, do: latest.input.cursor)
      )

    latest_user =
      dialogue |> Enum.filter(&(&1.speaker == :user)) |> List.last() |> Map.fetch!(:text)

    %{
      dialogue: dialogue,
      latest_user: latest_user,
      active:
        if(latest,
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
      pending_request: pending_request(snapshot),
      verified_offers: verified_offers(snapshot),
      dates: BookingDesk.Store.dates(),
      today: "2026-11-02",
      timezone: "America/Denver",
      interpretation_binding: %{
        session_id: snapshot.session_id,
        provider_generation: snapshot.provider_generation,
        caller_cursor: cursor,
        application_context: snapshot.application_context,
        tasks:
          Map.new(snapshot.tasks, fn {id, task} ->
            {id, Map.take(task, [:revision, :status, :input, :request_ids, :progress])}
          end)
      }
    }
  end

  defp interpret_request(snapshot, pending, latest, cursor, opts) do
    # Coalesce a bounded caller fragment before interpreting it.
    Process.sleep(Keyword.get(opts, :coalesce_ms, 180))
    state = request_state(snapshot, latest, cursor)
    judge = Keyword.get(opts, :judge, &BookingDesk.Judgment.classify/1)
    result = judge.(state)

    identity? =
      match?({:ok, %{"intent" => "lookup"}}, result) or
        (patient(snapshot) == nil and BookingDesk.Identity.requested_in?(state.dialogue))

    extractor = Keyword.get(opts, :identity_extractor, &Extractor.check/1)
    demographics = if identity?, do: extractor.(state), else: :not_requested

    context = %{
      snapshot: snapshot,
      pending: pending,
      latest: latest,
      cursor: cursor,
      text: state.latest_user,
      demographics: demographics
    }

    continue_demographics(context, state, result, opts)
  end

  defp continue_demographics(%{demographics: :pending} = context, _, _, _),
    do: await_field(context, "identity")

  defp continue_demographics(context, state, result, opts) do
    carrier = extract_carrier(result, state, opts)
    continue_carrier(context, result, carrier)
  end

  defp extract_carrier({:ok, %{"intent" => "insurance_update"}}, state, opts) do
    extract =
      Keyword.get(opts, :insurance_extractor, fn state ->
        Extractor.check(state, BookingDesk.InsuranceExtractor)
      end)

    extract.(state)
  end

  defp extract_carrier(_, _, _), do: :not_requested

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
      context.demographics
    )
  end

  defp bind_demographics({:ok, judgment}, {status, _}) when status in [:ok, :incomplete],
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

  defp interpreted(snapshot, _result, pending, latest, cursor, latest_user, {:error, _} = failure) do
    decide(
      snapshot,
      {:ok, %{"intent" => "lookup"}},
      pending,
      latest,
      cursor,
      latest_user,
      failure
    )
  end

  defp interpreted(snapshot, result, pending, latest, cursor, latest_user, demographics) do
    uncertain =
      uncertain_result?(result) or match?({:incomplete, _}, demographics) or
        partial_approval?(latest, result, latest_user)

    # A semantic approval can precede its complete spoken wording ("Yeah, go ...").
    # Keep the literal consent check, but give later fragments the same bounded
    # context window as uncertain interpretations before asking a clarification.

    if uncertain && (latest == nil || latest.input.operation != "confirm") do
      entry = latest || (pending && elem(pending, 1))
      key = "uncertain:#{cursor}"

      if match?(%{context_wait: %{expired?: true, recheck_key: ^key}}, entry) do
        decide(snapshot, result, pending, latest, cursor, latest_user, demographics)
      else
        target =
          wait_target(pending, latest)

        {:ok, [%{target | recheck_after_ms: 1_500, recheck_key: key}]}
      end
    else
      decide(snapshot, result, pending, latest, cursor, latest_user, demographics)
    end
  end

  defp uncertain_result?({:ok, %{"intent" => intent}}),
    do: intent in ["insurance_same", "insurance_changed", "unclear"]

  defp uncertain_result?({:ok, _}), do: false
  defp uncertain_result?(_), do: true

  defp partial_approval?(
         %{input: %{operation: "propose"}},
         {:ok, %{"intent" => "confirm"}},
         text
       ),
       do: not explicit_confirmation?(text)

  defp partial_approval?(_, _, _), do: false

  def decide(snapshot, result, pending, latest, cursor, text, demographics \\ :not_requested) do
    case result do
      {:incomplete, _, _} when not is_nil(latest) and latest.input.operation == "confirm" ->
        {:ok, associate(pending, latest)}

      {:incomplete, judgment, missing} ->
        clarify_booking(snapshot, cursor, pending, latest, judgment, missing)

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

      _ when not is_nil(latest) and latest.input.operation == "confirm" ->
        # Ambiguous progress speech cannot hold a verified write result hostage.
        # The admitted immutable proposal remains authoritative; do not retry it.
        {:ok, associate(pending, latest)}

      {:error, :unavailable} ->
        clarify(
          cursor,
          pending,
          latest,
          "I'm having trouble checking that request right now. Please try again in a moment. Nothing has been changed."
        )

      _ ->
        clarify(
          cursor,
          pending,
          latest,
          "Could you clarify what appointment help you need? Nothing has been changed."
        )
    end
  end

  defp decide_intent(intent, _judgment, %{pending: pending, latest: latest})
       when intent in ["none", "progress"] do
    {:ok, associate(pending, latest)}
  end

  defp decide_intent(intent, judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor
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

      intent == "insurance_same" and current.confirmed ->
        {:ok, associate(pending, latest)}

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

        input =
          base(snapshot, cursor)
          |> Map.merge(%{
            operation: "insurance",
            response: response,
            carrier: carrier,
            insurance_revision: current.revision,
            date: if(latest, do: Map.get(latest.input, :date)),
            clinician: clinician_preference(judgment, latest)
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
          |> Map.merge(%{operation: "availability", date: date, clinician: clinician})

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
        input =
          Map.merge(demographics, %{
            operation: "lookup",
            session: snapshot.session_id,
            cursor: cursor,
            date: judgment["date"],
            clinician: clinician_preference(judgment, latest)
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
        message =
          case missing do
            {:incomplete, [:name]} ->
              "Could I have your full name so I can find your record?"

            {:incomplete, [:dob]} ->
              "Could I have your complete date of birth, including the year?"

            _ ->
              "Could you clarify your full name and date of birth so I can find your record?"
          end

        clarify(cursor, pending, latest, message)
    end
  end

  defp decide_intent(intent, judgment, %{
         snapshot: snapshot,
         pending: pending,
         latest: latest,
         cursor: cursor
       })
       when intent in ["choose_slot", "reschedule"] do
    date = judgment["date"]
    time = judgment["time"]

    verified = completed_search(snapshot, date)
    clinician = clinician_preference(judgment, verified)
    candidates = slot_candidates(snapshot, verified, date, time, clinician)

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

  defp decide_intent("cancel", _judgment, %{
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
        appointment: "appt_existing",
        revision: cursor
      })

    {:ok, start(pending, latest, input)}
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
         confirmation_matches?(proposal, judgment) do
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
       }) do
    {:ok, associate(pending, latest)}
  end

  defp decide_intent(_, _judgment, %{cursor: cursor, pending: pending, latest: latest}) do
    clarify(
      cursor,
      pending,
      latest,
      "Could you give the exact date and time, or tell me which scheduling action you want?"
    )
  end

  defp completed_search(snapshot, date) do
    snapshot.tasks
    |> Map.values()
    |> Enum.filter(
      &(&1.status == :completed and &1.input.operation == "availability" and &1.input.date == date)
    )
    |> Enum.max_by(& &1.input.cursor, fn -> nil end)
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
        appointment: "appt_existing",
        revision: cursor,
        search_cursor: verified.input.cursor
      })

    if latest && latest.input.operation == "propose" &&
         latest.input.slot == input.slot && latest.input.change == input.change,
       do: {:ok, associate(pending, latest)},
       else: {:ok, start(pending, latest, input)}
  end

  defp availability_decisions(intent, pending, latest, input) do
    cond do
      same_search?(latest, input) -> associate(pending, latest)
      replacement_search?(intent, latest) -> replace_search(pending, latest, input)
      true -> start(pending, latest, input)
    end
  end

  defp same_search?(latest, input),
    do:
      latest && latest.input.operation == "availability" &&
        latest.input.date == input.date && Map.get(latest.input, :clinician) == input.clinician

  defp replacement_search?(intent, latest),
    do: intent == "replace_search" && latest && latest.input.operation == "availability"

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
      judgment
      |> Map.take(["intent", "date", "clinician", "time"])
      |> Enum.filter(fn
        {"intent", value} ->
          value in ~w(availability replace_search additional_search choose_slot reschedule)

        {"date", value} ->
          value in BookingDesk.Store.dates()

        {"clinician", value} ->
          value in ~w(lee patel any)

        {"time", value} ->
          value in ~w(10:15 14:00)
      end)
      |> Map.new()

    message =
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
          "Could you clarify what appointment help you need? Nothing has been changed."
      end

    lookup = identity(snapshot)

    clarify(cursor, pending, latest, message, %{
      booking_request: request,
      lookup_request: if(lookup, do: lookup.lookup_request)
    })
  end

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
      %{input: %{booking_request: request, lookup_request: ^expected}} -> request
      _ -> %{}
    end
  end

  defp verified_offers(snapshot) do
    search =
      snapshot.tasks
      |> Map.values()
      |> Enum.filter(&(&1.input.operation == "availability"))
      |> Enum.max_by(& &1.input.cursor, fn -> nil end)

    case {search, identity(snapshot), insurance(snapshot)} do
      {%{status: :completed, input: input}, %{patient: patient, lookup_request: lookup},
       %{confirmed: true, insurance_request: insurance}} ->
        if Map.get(input, :patient) == patient and Map.get(input, :lookup_request) == lookup and
             Map.get(input, :insurance_request) == insurance do
          BookingDesk.Store.offered(patient, input.cursor, lookup)
          |> Enum.map(&Map.take(&1, [:date, :time, :clinician]))
        else
          []
        end

      _ ->
        []
    end
  end

  def current_proposal(snapshot) do
    case {latest_task(snapshot), identity(snapshot)} do
      {%{
         status: :completed,
         input: %{operation: "propose", revision: revision} = input,
         request_ids: [id | _]
       }, %{patient: patient, lookup_request: lookup}} ->
        if input.patient == patient and input.lookup_request == lookup do
          stored_proposal(input, id, patient, lookup, revision)
        end

      _ ->
        nil
    end
  end

  defp stored_proposal(%{change: "cancel"}, id, patient, _lookup, revision) do
    case Enum.find(BookingDesk.Store.proposals(), fn [request, owner, _, _, _, rev, status] ->
           request == id and owner == patient and rev == revision and status == "pending"
         end) do
      [^id, ^patient, "cancel", slot, _, ^revision, "pending"] ->
        %{id: id, change: "cancel", slot: slot, revision: revision}

      _ ->
        nil
    end
  end

  defp stored_proposal(input, id, patient, lookup, revision) do
    case BookingDesk.Store.readback_proposal(patient, id, revision) do
      %{lookup_request: ^lookup, slot: slot} = proposal when slot == input.slot ->
        Map.take(proposal, [:id, :change, :slot, :revision, :clinician_id])

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

  defp explicit_confirmation?(text) do
    Regex.match?(
      ~r/\b(yes|confirm|go ahead|please book|please cancel|please reschedule)\b/i,
      text
    ) &&
      not Regex.match?(~r/\b(no|not|don't|unless|if|maybe|perhaps|wait|instead)\b/i, text)
  end

  def identity(snapshot, store \\ BookingDesk.Store) do
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
    date = Map.get(lookup.input, :date)
    clinician = Map.get(lookup.input, :clinician)

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

        if pending do
          {:ok, start(pending, lookup, input)}
        else
          {:ok,
           [
             %D{
               kind: :start_task,
               anchor_task_id: lookup.id,
               expected_anchor_revision: lookup.revision,
               input: input
             }
           ]}
        end
    end
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
           clarification_key: "caller:#{cursor}:#{message}"
       }
     ]}
  end
end
