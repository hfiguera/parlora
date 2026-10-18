defmodule OrderDesk.Clarification do
  @moduledoc "Application-owned partial request retained across clarification questions."
  alias OrderDesk.Speech

  # A captioned request is enough to avoid competing questions, but never
  # evidence of business intent or proof that the caller heard the question.
  def coordinate(result, snapshot, options \\ [])

  def coordinate(
        {:ok, decisions},
        %{application_context: %{voice_provider: provider}} = snapshot,
        options
      )
      when provider in [:gemini, :grok] do
    recent = Enum.take_while(snapshot.transcripts, &(&1.speaker == :assistant))

    assistant =
      recent
      |> Enum.reverse()
      |> Enum.map_join(& &1.delta)
      |> String.trim()

    hold = snapshot.application_context[:save_announcement_until_ms]

    remaining =
      if is_integer(hold), do: max(0, hold - System.monotonic_time(:millisecond)), else: 0

    {:ok,
     Enum.map(decisions, fn decision ->
       cond do
         decision.kind != :request_clarification ->
           decision

         remaining > 0 ->
           %{
             decision
             | kind: :wait_for_context,
               message: nil,
               recheck_after_ms: min(remaining, 60_000),
               recheck_key: "save-announcement:#{hold}"
           }

         snapshot.provider_speech == :speaking ->
           # Session admission defers this against fresh context, without model I/O.
           decision

         assistant == "" ->
           decision

         snapshot.provider_speech == :idle ->
           coordinate_idle(decision, snapshot, assistant, options)

         clarification_prompt?(assistant) ->
           # Legacy snapshots lack a speech boundary; retain the existing behavior.
           %{decision | kind: :wait_for_context, message: nil, recheck_after_ms: nil}

         true ->
           decision
       end
     end)}
  end

  def coordinate(result, _snapshot, _options), do: result

  defp coordinate_idle(decision, snapshot, assistant, options) do
    revision = OrderDesk.CallerHistory.revision(snapshot.transcripts)

    target =
      if decision.task_id,
        do: {:task, decision.task_id, decision.expected_task_revision},
        else: {:delegation, decision.delegation_id}

    key = {snapshot.session_id, revision, target}

    window =
      Keyword.get(options, :clarification_window, &OrderDesk.Interpretation.coordination_window/1)

    if window.(key) == 0 do
      decision
    else
      state = %{
        assistant: assistant,
        recent_dialogue: OrderDesk.CallerHistory.dialogue(snapshot.transcripts),
        proposed: %{
          message: decision.message,
          input:
            Map.take(decision.input, [
              :missing,
              :known_order,
              :known_operation,
              :candidate_order,
              :candidate_operation
            ])
        }
      }

      judge =
        Keyword.get(options, :clarification_judge, fn state ->
          OrderDesk.Interpretation.clarification(state,
            session_id: snapshot.session_id,
            context_revision: snapshot.revision
          )
        end)

      result =
        if :erlang.external_size(state) <= 16_384, do: judge.(state), else: {:error, :size_limit}

      suppress? =
        case result do
          {:ok, "covered"} -> true
          {:ok, "different"} -> false
          _uncertain -> clarification_prompt?(assistant)
        end

      # Re-read the absolute deadline after inference; slow/error responses never
      # grant a fresh waiting interval. The policy runner rejects stale snapshots.
      remaining = window.(key)

      if suppress? and remaining > 0 do
        %{
          decision
          | kind: :wait_for_context,
            message: nil,
            recheck_after_ms: remaining,
            recheck_key: "#{revision}:coverage"
        }
      else
        decision
      end
    end
  end

  # Bounded English request forms, including the observed declarative number
  # request and browser confirmation prompt. Only the final sentence qualifies;
  # an earlier request must not hide a clarification after a subsequent answer.
  # This is a coordination cue, never proof of hearing or business authorization.
  defp clarification_prompt?(text) do
    String.ends_with?(text, "?") or
      Regex.match?(
        ~r/(?:\A|[.!?]\s+)(?:please\s+)?(?:provide|say|repeat|tell me)\s+(?:(?:a|the|your)\s+)?(?:three[- ]digit\s+)?(?:order number|delivery instructions)\b[^.!?]*[.!]?\z/iu,
        text
      ) or
      Regex.match?(
        ~r/(?:\A|[.!?]\s+)i need\s+(?:a|the|your)\s+(?:three[- ]digit\s+)?order number\b[^.!?]*[.!]?\z/iu,
        text
      ) or
      Regex.match?(
        ~r/(?:\A|[.!?]\s+)please review\b[^.!?]*\b(?:press|click) confirm\b[^.!?]*\bsave\b[^.!?]*[.!]?\z/iu,
        text
      )
  end

  def number_reply(recovery, text) do
    input = get_in(recovery, [:entry, :clarification, :input]) || %{}
    order = Speech.number_reply(text) || Speech.read_correction(text)

    if order && !Map.get(input, :number_pending?, false) &&
         "operation" in Map.get(input, :missing, []) &&
         input[:candidate_operation] not in ["status", "items", "instructions"],
       do:
         input
         |> Map.merge(%{known_order: order, missing: ["operation"]})
         |> Map.delete(:candidate_order)
  end

  def number_input(recovery, text) do
    previous = get_in(recovery, [:entry, :clarification, :input]) || %{}
    operation = previous[:known_operation]

    previous
    |> Map.delete(:candidate_order)
    |> Map.merge(%{
      known_order: nil,
      known_operation: operation,
      missing: ["order"] ++ if(operation, do: [], else: ["operation"]),
      number_pending?: true
    })
    |> remember(text)
  end

  # Keep the actual unfinished request, not a guessed business operation. Leave
  # overlong text out rather than truncating it into a different request.
  def remember(input, text) when is_binary(text) and byte_size(text) <= 2_048,
    do: Map.put(input, :request_text, text)

  def remember(input, _text), do: Map.delete(input, :request_text)

  def input(judgment, text, current_order?, recovery) do
    uncertain = Map.get(judgment, :uncertain_fields, [])
    literal = Speech.number_reply(text) || Speech.read_correction(text)
    pending_order = get_in(recovery, [:entry, :clarification, :input, :known_order])

    retained? =
      pending_order && Speech.numbers(text) in [[], [pending_order]] &&
        not Speech.changed_order_reference?(text)

    known_order =
      cond do
        literal ->
          literal

        retained? ->
          pending_order

        judgment.order != "unknown" and ("target" not in uncertain or current_order?) ->
          judgment.order

        true ->
          nil
      end

    known_operation =
      if judgment.intent in [
           "status",
           "items",
           "instructions",
           "delivery",
           "followup",
           "refuse",
           "cancel"
         ] and
           "intent" not in uncertain,
         do: judgment.intent

    # Preserve a complete ID for a targeted question without upgrading a low
    # confidence target to known_order. A subsequent judgment must still resolve it.
    candidate_order =
      if is_nil(known_order) do
        pending_candidate = get_in(recovery, [:entry, :clarification, :input, :candidate_order])

        Speech.clarification_number(text) ||
          if(
            pending_candidate && not Speech.number_mentioned?(text) &&
              not Speech.changed_order_reference?(text),
            do: pending_candidate
          )
      end

    target_confirmation? =
      candidate_order != nil or ("target" in uncertain and known_order != nil and literal == nil)

    input = %{
      known_order: known_order,
      known_operation: known_operation,
      missing:
        if(known_order || candidate_order, do: [], else: ["order"]) ++
          if(known_operation, do: [], else: ["operation"]) ++
          if("relationship" in uncertain, do: ["relationship"], else: []) ++
          if(target_confirmation?, do: ["target_confirmation"], else: [])
    }

    input = if candidate_order, do: Map.put(input, :candidate_order, candidate_order), else: input

    if "intent" in uncertain and
         judgment.intent in [
           "status",
           "items",
           "instructions",
           "delivery",
           "refuse",
           "cancel",
           "followup"
         ], do: Map.put(input, :candidate_operation, judgment.intent), else: input
  end

  def question(%{known_order: nil, candidate_order: order} = input) when is_binary(order) do
    if input[:known_operation] || input[:candidate_operation] do
      question(%{input | known_order: order})
    else
      "Do you mean order #{order}? What would you like to check: delivery status, items, or saved delivery instructions?"
    end
  end

  def question(%{known_order: order, known_operation: operation, missing: ["relationship"]}),
    do:
      "Do you want #{label(operation)} for order #{order} in addition to the previous request, or instead?"

  def question(%{known_order: nil, known_operation: operation}) when is_binary(operation),
    do: "Please clarify the three-digit order number for #{label(operation)}."

  def question(%{known_order: nil}),
    do: "Please clarify the request and say the three-digit order number."

  def question(%{known_order: order, candidate_operation: operation}),
    do: "Do you mean #{label(operation)} for order #{order}?"

  def question(%{known_order: order, known_operation: operation}) when is_binary(operation),
    do: "Please confirm: do you mean #{label(operation)} for order #{order}?"

  def question(%{known_order: order}),
    do:
      "For order #{order}, are you asking about the earlier lookup, delivery status, items, delivery instructions, or rejecting a draft?"

  defp label("status"), do: "the delivery status"
  defp label("items"), do: "the items"
  defp label("instructions"), do: "the saved delivery instructions"
  defp label("delivery"), do: "drafting new delivery instructions"
  defp label("followup"), do: "the earlier lookup"
  defp label("refuse"), do: "refusing a delivery draft"
  defp label("cancel"), do: "stopping the lookup"

  def reply(marker, text, active) do
    # Legacy snapshots had no application input. Newly created questions never
    # borrow an operation from a completed task when that operation is unresolved.
    previous =
      if marker[:input] not in [nil, %{}],
        do: marker.input[:known_operation],
        else: active && active.operation

    %{
      text: text,
      question: if(marker[:delivery] != :unconfirmed, do: marker[:message]),
      submitted_question: marker[:message],
      delivery: marker[:delivery],
      pending_request: marker[:input],
      previous_operation: previous,
      number_reply: Speech.number_reply(text) || Speech.read_correction(text)
    }
  end
end
