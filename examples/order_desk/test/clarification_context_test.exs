defmodule OrderDesk.ClarificationContextTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger, Event}

  test "equivalent repetitions stay one ID; conflicts and unfinished repeats do not" do
    for text <- [
          "one hundred twenty four, one two four",
          "124, 124",
          "one, two, four",
          "ONE, TWENTY, FOUR"
        ] do
      assert Speech.numbers(text) == ["124"]
      assert Speech.number_reply(text) == "124"
    end

    assert Speech.numbers("one hundred twenty three, one two four") == ["123", "124"]
    assert Speech.numbers("123, 124") == ["123", "124"]

    for text <- [
          "one hundred twenty four, one two",
          "123, 124",
          "one hundred twenty three, one two four",
          "not 124",
          "124 or 123",
          "",
          "124 cancel it"
        ] do
      assert Speech.number_reply(text) == nil
    end
  end

  test "number replies update an unknown operation without reasking the number or executing old work" do
    classify = fn state ->
      case state.latest_caller_segment do
        "Check order 124" ->
          {:ok, %{intent: "status", order: "124"}}

        "What items are in that order?" ->
          assert state.clarification_reply.pending_request.known_order == "123"
          assert "123" in state.order_candidates
          assert state.clarification_reply.previous_operation == nil
          assert state.clarification_reply.question == nil
          assert state.clarification_reply.submitted_question =~ "For order 123"
          assert state.clarification_reply.delivery == :unconfirmed
          {:ok, %{intent: "items", order: "123"}}

        _ ->
          {:ok, %{intent: "unclear", order: "124"}}
      end
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           [classify: classify, clarification_settle_ms: 60, clarification_verify_ms: 30]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    ScriptedProvider.say(provider, "Check order 124")
    ScriptedProvider.delegate(provider, "lookup")
    event(:task_submitted)
    context("out for delivery")

    for {text, order} <- [
          {"Do you know what it is, order", "124"},
          {"one hundred twenty four, one two four", "124"},
          {"One hundred twenty three", "123"}
        ] do
      ScriptedProvider.say(provider, text)
      ScriptedProvider.delegate(provider, "question-#{text}")
      context("For order #{order}")
      event(:clarification_requested)
      assert map_size(Parlora.status(session).jobs) == 1
      [task] = Map.values(Parlora.snapshot(session).tasks)

      assert Map.take(task.clarification.input, [:known_order, :known_operation, :missing]) == %{
               known_order: order,
               known_operation: nil,
               missing: ["operation"]
             }

      # Establish a non-overlapping assistant boundary for the next caller segment.
      ScriptedProvider.transcript(provider, %{speaker: :assistant, delta: "What information?"})
    end

    ScriptedProvider.say(provider, "What items are in that order?")
    request = event(:task_submitted).payload.request
    assert request.input.order == "123"
    assert request.input.operation == "items"
    context("Travel mug")
  end

  test "classifier receives the question and known pending operation instead of the completed operation" do
    snapshot = %ContextSnapshot{
      session_id: "pending",
      tasks: %{
        "task" => %{
          revision: 1,
          status: :completed,
          input: %{order: "123", operation: "status", instructions: nil, user_revision: 1},
          clarification: %{
            context_revision: 2,
            message: "Which order's items?",
            input: %{known_order: nil, known_operation: "items", missing: ["order"]}
          }
        }
      },
      pending_delegations: %{"d" => %{status: :pending}},
      transcripts: [
        %{speaker: :user, delta: "one hundred twenty four, one two four", arrival_order: 3}
      ]
    }

    assert {:ok, [%{kind: :start_task, input: %{order: "124", operation: "items"}}]} =
             AppPolicy.interpret(snapshot, %ContextTrigger{},
               classify: fn state ->
                 assert state.clarification_reply.number_reply == "124"
                 assert state.clarification_reply.previous_operation == "items"
                 assert state.clarification_reply.question == "Which order's items?"
                 {:ok, %{intent: "items", order: "124"}}
               end
             )
  end

  test "a retained clarification order remains a candidate after older captions disappear" do
    snapshot = %ContextSnapshot{
      session_id: "trimmed",
      tasks: %{
        "task" => %{
          revision: 1,
          status: :completed,
          input: %{order: "124", operation: "status", user_revision: 1},
          clarification: %{
            context_revision: 2,
            message: "What about order 123?",
            input: %{known_order: "123", known_operation: nil, missing: ["operation"]}
          }
        }
      },
      pending_delegations: %{"d" => %{status: :pending}},
      transcripts: [%{speaker: :user, delta: "What items are in that order?", arrival_order: 3}]
    }

    assert {:ok, [%{kind: :start_task, input: %{order: "123", operation: "items"}}]} =
             AppPolicy.interpret(snapshot, %ContextTrigger{},
               classify: fn state ->
                 assert "123" in state.order_candidates
                 assert state.clarification_reply.pending_request.known_order == "123"
                 {:ok, %{intent: "items", order: "123"}}
               end
             )
  end

  test "a partial number question retains the known operation" do
    snapshot = %ContextSnapshot{
      session_id: "partial-number",
      tasks: %{
        "task" => %{
          revision: 1,
          status: :completed,
          input: %{order: "124", operation: "status", user_revision: 1},
          context_wait: %{recheck_key: "3:verify", expired?: true},
          clarification: %{
            context_revision: 2,
            message: "Which order's items?",
            input: %{known_order: nil, known_operation: "items", missing: ["order"]}
          }
        }
      },
      pending_delegations: %{"d" => %{status: :pending}},
      transcripts: [%{speaker: :user, delta: "one two", arrival_order: 3}]
    }

    assert {:ok, [%{kind: :request_clarification, input: input}]} =
             AppPolicy.interpret(snapshot, %ContextTrigger{},
               classify: fn _ -> flunk("Incomplete number") end
             )

    assert Map.take(input, [:known_order, :known_operation, :missing]) == %{
             known_order: nil,
             known_operation: "items",
             missing: ["order"]
           }

    assert input.request_text == "one two"
    assert input.number_pending?
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      2_000 -> flunk("Missing #{type}")
    end
  end

  defp context(text) do
    receive do
      {:context, update} -> assert update.content =~ text
    after
      2_000 -> flunk("Missing context #{text}")
    end
  end
end
