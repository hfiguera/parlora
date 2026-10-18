defmodule OrderDesk.DeliveryContinuationTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger, ContextUpdate, Event}

  defp fragment(speaker, text, revision),
    do: %{speaker: speaker, delta: text, arrival_order: revision, timing: :unavailable}

  defp snapshot(operation, handled, fresh) do
    %ContextSnapshot{
      session_id: Parlora.ID.new(),
      revision: 2,
      provider_speech: :idle,
      application_context: %{voice_provider: :gemini},
      transcripts: [fragment(:user, fresh, 2), fragment(:user, handled, 1)],
      tasks: %{
        "task" => %{
          revision: 1,
          status: :completed,
          request_ids: [],
          input: %{
            order: "124",
            operation: operation,
            instructions: if(operation == "delivery", do: Speech.delivery(handled)),
            request_text: handled,
            user_revision: 1
          },
          context_wait: %{expired?: true, recheck_key: "2:verify"}
        }
      }
    }
  end

  defp decide(s, classify),
    do:
      AppPolicy.interpret(s, %ContextTrigger{},
        classify: classify,
        clarification_window: fn _ -> 0 end
      )

  test "pure presence checks do not reopen an admitted lookup" do
    for text <- ["Are you still there?", "Hello? Can you hear me?"] do
      s = snapshot("instructions", "What about the delivery instructions?", text)

      assert {:ok, []} =
               decide(s, fn state ->
                 assert state.new_caller_text == text
                 {:ok, %{intent: "presence", order: "unknown"}}
               end)
    end
  end

  test "a presence check preserves an unanswered business clarification" do
    s = snapshot("instructions", "What about the delivery instructions?", "Are you there?")

    task =
      s.tasks["task"]
      |> Map.put(:clarification, %{context_revision: 1, input: %{missing: ["order"]}})

    s = %{s | tasks: %{"task" => task}}

    assert {:ok, [%{kind: :wait_for_context, task_id: "task"}]} =
             decide(s, fn _ -> {:ok, %{intent: "presence", order: "unknown"}} end)
  end

  test "presence mixed with a new business request still changes the target" do
    s = snapshot("status", "Check order 124", "Are you there? Check order 123.")

    assert {:ok, [%{kind: :supersede_task, input: %{order: "123"}}]} =
             decide(s, fn _ -> {:ok, %{intent: "status", order: "123"}} end)
  end

  test "an uninterrupted delivery restatement associates existing literal work" do
    s =
      snapshot(
        "delivery",
        "Let's exchange that food left on my neighbor.",
        " Yes.I want to change the delivery instructions."
      )

    s = %{s | pending_delegations: %{"d" => %{status: :pending}}}

    assert {:ok, [%{kind: :associate_delegation, task_id: "task", delegation_id: "d"}]} =
             decide(s, fn state ->
               assert state.delivery_continuation_eligible
               {:ok, %{intent: "delivery_continuation", order: "124"}}
             end)
  end

  test "a new destination is never mistaken for a restatement" do
    s = snapshot("delivery", "Leave with my neighbor.", "Actually, leave at reception.")

    s = %{
      s
      | tasks: %{
          "task" => %{
            s.tasks["task"]
            | context_wait: %{expired?: true, recheck_key: "2:delivery"}
          }
        }
    }

    assert {:ok, [%{kind: :supersede_task, input: %{instructions: "leave at reception"}}]} =
             decide(s, fn state ->
               refute state.delivery_continuation_eligible
               {:ok, %{intent: "delivery", order: "124"}}
             end)
  end

  test "a separate edit after an assistant response asks for new wording without denying an existing draft" do
    actor = "fragment-#{Parlora.ID.new()}"
    id = Parlora.ID.new()
    {:ok, _} = OrderDesk.Store.propose(actor, "124", "Leave with my neighbor", id)

    s =
      snapshot(
        "delivery",
        "Leave with my neighbor",
        "I want to change the delivery instructions."
      )

    s = %{
      s
      | revision: 3,
        application_context: %{voice_provider: :gemini, actor: actor},
        transcripts: [
          fragment(:user, "I want to change the delivery instructions.", 3),
          fragment(:assistant, "Please review the draft on the page.", 2),
          fragment(:user, "Leave with my neighbor", 1)
        ],
        tasks: %{
          "task" => %{
            s.tasks["task"]
            | request_ids: [id],
              context_wait: %{expired?: true, recheck_key: "3:verify"}
          }
        }
    }

    assert {:ok, [question]} =
             decide(s, fn state ->
               refute state.delivery_continuation_eligible
               {:ok, %{intent: "delivery", order: "124"}}
             end)

    assert question.kind == :request_clarification
    assert question.message =~ "An existing draft for order 124 says: Leave with my neighbor"
    refute question.message =~ "No draft has been created"
    assert question.input.missing == ["instructions"]
  end

  defp event(source, type) do
    receive do
      {:parlora_event, %Event{source: ^source, type: ^type} = e} -> e
    after
      2_000 -> flunk("Missing #{source}:#{type}")
    end
  end

  test "streamed edit tail releases the completed draft once and a later replacement remains possible" do
    {:ok, %{version: original_version}} = OrderDesk.Store.order("124")
    delays = Application.get_env(:order_desk, :lookup_delays, %{})
    Application.put_env(:order_desk, :lookup_delays, %{"124" => 100})
    on_exit(fn -> Application.put_env(:order_desk, :lookup_delays, delays) end)
    actor = "session-fragment-#{Parlora.ID.new()}"

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{voice_provider: :gemini, actor: actor},
        context_policy:
          {AppPolicy,
           [
             classify: fn state ->
               intent =
                 if state.delivery_continuation_eligible,
                   do: "delivery_continuation",
                   else: "delivery"

               {:ok, %{intent: intent, order: "124"}}
             end,
             clarification_settle_ms: 40,
             clarification_verify_ms: 20,
             delivery_settle_ms: 20
           ]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:session, :ready)

    ScriptedProvider.transcript(
      provider,
      Map.drop(fragment(:user, "Let's exchange that food left on my neighbor.", 0), [
        :arrival_order
      ])
    )

    ScriptedProvider.delegate(provider, "edit")
    first = event(:session, :task_submitted).payload.request

    ScriptedProvider.transcript(
      provider,
      Map.drop(fragment(:user, " Yes.I want to change the delivery instructions.", 0), [
        :arrival_order
      ])
    )

    event(:backend, :request_completed)
    assert_receive {:context, %ContextUpdate{task_id: task, content: summary}}, 1_000
    assert task == first.task_id
    assert summary =~ "A draft for order 124 says: left on my neighbor"
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 100
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 30
    refute_receive {:context, _}, 30

    assert %{instructions: "left on my neighbor", status: "pending"} =
             Enum.find(OrderDesk.Store.dashboard(actor).proposals, &(&1.id == first.id))

    ScriptedProvider.transcript(
      provider,
      Map.drop(fragment(:assistant, "Please review the draft.", 0), [:arrival_order])
    )

    ScriptedProvider.transcript(
      provider,
      Map.drop(fragment(:user, "Actually, leave at reception.", 0), [:arrival_order])
    )

    replacement = event(:session, :task_submitted).payload.request
    assert replacement.task_revision == first.task_revision + 1
    assert replacement.input.instructions == "leave at reception"
    event(:backend, :request_completed)
    assert_receive {:context, %ContextUpdate{content: content}}, 1_000
    assert content =~ "A draft for order 124 says: leave at reception"
    assert {:ok, %{version: ^original_version}} = OrderDesk.Store.order("124")
  end
end
