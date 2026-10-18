defmodule OrderDesk.RetryLookupTest do
  use ExUnit.Case, async: true
  alias OrderDesk.AppPolicy
  alias Parlora.{ContextSnapshot, ContextTrigger}

  test "explicit retry creates a fresh anchored read for each read operation" do
    for operation <- ["status", "items", "instructions"], status <- [:running, :completed] do
      s = snapshot(operation, status)
      assert {:ok, [attempt, _recheck]} = decide(s, "retry_lookup")
      assert attempt.kind == :start_task
      assert attempt.anchor_task_id == "old"
      assert attempt.expected_anchor_revision == 2
      assert attempt.task_id == nil
      assert attempt.input.operation == operation
      assert attempt.input.retry? == true
      assert attempt.input.order == "134"
      assert attempt.input.user_revision == 3
      assert attempt.input.request_text == "Just try again"

      # Admission records the retry's caller revision. Late delegations attach to it.
      next = put_in(s.tasks["retry"], %{revision: 1, input: attempt.input, status: :running})

      assert {:ok, [%{kind: :associate_delegation, task_id: "retry"}]} =
               AppPolicy.interpret(next, %ContextTrigger{},
                 classify: fn _ -> flunk("duplicate") end
               )

      # Recording retry provenance must not suppress a later explicit retry.
      later = %{
        next
        | transcripts: [
            %{speaker: :user, delta: "Try once more", arrival_order: 5} | next.transcripts
          ]
      }

      assert {:ok, [%{kind: :start_task, anchor_task_id: "retry"}, _]} =
               decide(later, "retry_lookup")
    end
  end

  test "interpreter receives retry provenance after early admission, including trailing speech" do
    original = snapshot("status")
    {:ok, [attempt, _]} = decide(original, "retry_lookup")

    task = %{
      revision: 1,
      status: :completed,
      input: %{attempt.input | request_text: "Please try"}
    }

    next = %{
      original
      | tasks: %{"retry" => task},
        transcripts: [
          %{speaker: :user, delta: " checking that order again", arrival_order: 4},
          %{speaker: :user, delta: "Please try", arrival_order: 3}
        ]
    }

    assert {:ok, [%{kind: :associate_delegation, task_id: "retry"}]} =
             AppPolicy.interpret(next, %ContextTrigger{},
               classify: fn state ->
                 assert state.active_task.retry? == true
                 assert hd(state.recent_work).retry? == true
                 assert state.handled_caller_input == "Please try"
                 assert state.new_caller_text == " checking that order again"
                 {:ok, %{intent: "handled_continuation", order: "134"}}
               end
             )
  end

  test "progress and identical read judgments do not implicitly retry" do
    for intent <- ["followup", "status"] do
      assert {:ok, [%{kind: :associate_delegation}]} = decide(snapshot("status"), intent)
    end
  end

  test "retry cannot replay delivery actions or invent a target" do
    for operation <- ["delivery", "refuse", "cancel"] do
      assert {:ok, [%{kind: :request_clarification}]} =
               decide(snapshot(operation), "retry_lookup")
    end

    for order <- ["unknown", "124"] do
      assert {:ok, [%{kind: :request_clarification}]} =
               decide(snapshot("status"), "retry_lookup", order)
    end
  end

  test "uncertain retries remain clarification, not execution" do
    assert {:ok, [%{kind: :request_clarification}]} =
             AppPolicy.interpret(snapshot("status"), %ContextTrigger{},
               classify: fn _ ->
                 {:error,
                  {:uncertain,
                   %{intent: "retry_lookup", order: "134", uncertain_fields: ["intent"]}}}
               end
             )
  end

  test "a live coordinator admits one retry and associates its late delegation" do
    classify = fn state ->
      intent = if state.new_caller_text =~ "try again", do: "retry_lookup", else: "status"
      {:ok, %{intent: intent, order: "134"}}
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {OrderDesk.ScriptedProvider, observer: self(), audio: false},
        context_policy: {AppPolicy, classify: classify}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    assert_receive {:parlora_event, %{source: :session, type: :ready}}, 1000
    OrderDesk.ScriptedProvider.say(provider, "Check order 134")
    OrderDesk.ScriptedProvider.delegate(provider, "initial")
    assert_receive {:parlora_event, %{type: :task_submitted, payload: %{request: first}}}, 1000
    assert_receive {:parlora_event, %{type: :request_completed}}, 1000

    OrderDesk.ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "I could not find that order"
    })

    OrderDesk.ScriptedProvider.say(provider, "Just try again")
    assert_receive {:parlora_event, %{type: :task_submitted, payload: %{request: retry}}}, 1000
    assert retry.task_id != first.task_id
    assert retry.input.order == "134"
    assert retry.input.operation == "status"
    OrderDesk.ScriptedProvider.delegate(provider, "late-retry")
    assert_receive {:parlora_event, %{type: :delegation_associated}}, 1000
    assert_receive {:parlora_event, %{type: :request_completed}}, 1000
    assert map_size(Parlora.status(session).jobs) == 2
    refute_receive {:parlora_event, %{type: :task_submitted}}, 100
  end

  defp decide(snapshot, intent, order \\ "134"),
    do:
      AppPolicy.interpret(snapshot, %ContextTrigger{},
        classify: fn _ -> {:ok, %{intent: intent, order: order}} end
      )

  defp snapshot(operation, status \\ :completed) do
    %ContextSnapshot{
      session_id: "retry",
      transcripts: [
        %{speaker: :user, delta: "Just try again", arrival_order: 3},
        %{speaker: :assistant, delta: "I could not find that order", arrival_order: 2},
        %{speaker: :user, delta: "Check order 134", arrival_order: 1}
      ],
      tasks: %{
        "old" => %{
          revision: 2,
          status: status,
          input: %{order: "134", operation: operation, user_revision: 1, instructions: nil},
          context_wait: %{expired?: true, recheck_key: "3:verify"}
        }
      },
      pending_delegations: %{"new" => %{status: :pending}}
    }
  end
end
