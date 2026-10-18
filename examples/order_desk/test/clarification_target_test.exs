defmodule OrderDesk.ClarificationTargetTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, Clarification, Interpretation, ScriptedProvider, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger, Event}

  defp snapshot(text, revision, marker \\ nil) do
    entry = %{
      status: :pending,
      context_wait: %{recheck_key: "#{revision}:verify", expired?: true}
    }

    entry = if marker, do: Map.put(entry, :clarification, marker), else: entry

    %ContextSnapshot{
      session_id: "clarification-target",
      revision: revision,
      application_context: %{voice_provider: :openai},
      pending_delegations: %{"lookup" => entry},
      transcripts: [%{speaker: :user, delta: text, arrival_order: revision}]
    }
  end

  defp marker(question, revision),
    do: %{
      context_revision: revision,
      input: question.input,
      message: question.message,
      delivery: :unconfirmed
    }

  defp decide(s, answer),
    do: AppPolicy.interpret(s, %ContextTrigger{}, classify: fn _ -> answer end)

  test "a low confidence complete target asks for confirmation without admitting work" do
    answers = %{
      "intent" => %{choice: "order_status", probabilities: %{"order_status" => 0.99}},
      "target" => %{choice: "123", probabilities: %{"123" => 0.78, "unknown" => 0.22}}
    }

    answer = Interpretation.interpret_answers(answers)
    assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} = answer
    assert {:ok, [q]} = decide(snapshot("Check order 123", 5), answer)
    assert q.kind == :request_clarification
    assert q.input.known_order == nil
    assert q.input.candidate_order == "123"
    assert q.input.missing == ["target_confirmation"]
    assert q.message == "Please confirm: do you mean the delivery status for order 123?"
  end

  test "short correction and repeated number resolve the target but never invent an operation" do
    uncertain =
      {:error, {:uncertain, %{intent: "unclear", order: "124", uncertain_fields: ["target"]}}}

    assert {:ok, [first]} = decide(snapshot("Yes, so the order 124", 5), uncertain)
    assert first.input.candidate_order == "124"

    assert {:ok, [corrected]} =
             AppPolicy.interpret(snapshot("Sorry, 123", 8, marker(first, 6)), %ContextTrigger{},
               classify: fn _ -> flunk("A complete correction does not invent an operation") end
             )

    assert corrected.kind == :request_clarification
    assert corrected.input.known_order == "123"
    assert corrected.input.missing == ["operation"]
    refute Map.has_key?(corrected.input, :candidate_order)
    assert corrected.message =~ "For order 123"
    refute corrected.message =~ "say the three-digit"

    assert {:ok, [repeated]} =
             AppPolicy.interpret(snapshot("123", 11, marker(corrected, 9)), %ContextTrigger{},
               classify: fn _ -> flunk("A number alone cannot supply an operation") end
             )

    assert repeated.input.known_order == "123"
    assert repeated.input.missing == ["operation"]

    assert {:ok, [%{kind: :start_task, input: %{order: "123", operation: "status"}}]} =
             AppPolicy.interpret(
               snapshot("Delivery status", 14, marker(repeated, 12)),
               %ContextTrigger{},
               classify: fn state ->
                 assert state.clarification_reply.pending_request.known_order == "123"
                 assert state.clarification_reply.previous_operation == nil
                 {:ok, %{intent: "status", order: "123"}}
               end
             )
  end

  test "unconfirmed targets survive trimmed history without becoming known orders" do
    pending = %{
      context_revision: 3,
      message: "Do you mean the delivery status for order 123?",
      input: %{
        known_order: nil,
        candidate_order: "123",
        known_operation: "status",
        missing: ["target_confirmation"]
      }
    }

    assert {:ok, [q]} =
             AppPolicy.interpret(snapshot("Delivery status", 5, pending), %ContextTrigger{},
               classify: fn state ->
                 assert "123" in state.order_candidates
                 assert state.clarification_reply.pending_request.known_order == nil

                 {:error,
                  {:uncertain,
                   %{intent: "status", order: "unknown", uncertain_fields: ["target"]}}}
               end
             )

    assert q.kind == :request_clarification
    assert q.input.known_order == nil
    assert q.input.candidate_order == "123"
    assert q.input.missing == ["target_confirmation"]
  end

  test "conflicting, negated and unfinished IDs are not confirmation candidates" do
    for text <- [
          "123 or 124",
          "not 123",
          "another order 123",
          "Check order one two",
          "123, one two",
          "123123"
        ] do
      assert Speech.clarification_number(text) == nil, text
    end

    recovery = %{entry: %{clarification: %{input: %{known_order: nil, candidate_order: "123"}}}}
    input = Clarification.number_input(recovery, "Sorry, 12")
    refute Map.has_key?(input, :candidate_order)
    assert input.number_pending?
    assert input.known_order == nil

    for text <- ["123123", "123 or 124", "one two three four", "another order"] do
      input =
        Clarification.input(
          %{intent: "status", order: "unknown", uncertain_fields: ["target"]},
          text,
          false,
          recovery
        )

      refute Map.has_key?(input, :candidate_order), text
      assert input.known_order == nil
    end
  end

  test "a fresh session corrects its target before any job and admits one lookup after the operation" do
    classify = fn state ->
      if state.new_caller_text == "Delivery status" do
        assert state.clarification_reply.pending_request.known_order == "123"
        {:ok, %{intent: "status", order: "123"}}
      else
        {:error, {:uncertain, %{intent: "unclear", order: "124", uncertain_fields: ["target"]}}}
      end
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           [classify: classify, clarification_settle_ms: 40, clarification_verify_ms: 30]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    ScriptedProvider.say(provider, "Yes, so the order 124")
    ScriptedProvider.delegate(provider, "initial")
    event(:clarification_requested)
    assert map_size(Parlora.status(session).jobs) == 0
    ScriptedProvider.transcript(provider, %{speaker: :assistant, delta: "What about order 124?"})
    ScriptedProvider.say(provider, "Sorry, 12")
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 50
    ScriptedProvider.say(provider, "3")
    event(:clarification_requested)
    assert map_size(Parlora.status(session).jobs) == 0
    [entry] = Map.values(Parlora.snapshot(session).pending_delegations)
    assert entry.clarification.input.known_order == "123"
    assert entry.clarification.input.missing == ["operation"]

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "What would you like to check for order 123?"
    })

    ScriptedProvider.say(provider, "Delivery status")
    request = event(:task_submitted).payload.request
    assert request.input.order == "123"
    assert request.input.operation == "status"
    assert map_size(Parlora.status(session).jobs) == 1
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      2_000 -> flunk("Missing #{type}")
    end
  end
end
