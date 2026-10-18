defmodule OrderDesk.NumberContinuationTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider, Speech}
  alias Parlora.{ContextSnapshot, ContextTrigger, Event}

  test "unfinished cardinal IDs wait before classification; valid 100 and 120 remain allowed" do
    for {text, order} <- [
          {"Check one hundred", "100"},
          {"Check one hundred twenty", "120"},
          {"Check one-twenty", "120"}
        ] do
      snapshot = %ContextSnapshot{
        session_id: "number-test",
        transcripts: [%{speaker: :user, delta: text, arrival_order: 5}],
        pending_delegations: %{"d" => %{status: :pending}}
      }

      assert {:ok, [%{kind: :wait_for_context, recheck_key: "5:number", recheck_after_ms: 600}]} =
               AppPolicy.interpret(snapshot, %ContextTrigger{},
                 classify: fn _ -> flunk("Unsettled number reached classifier") end
               )

      settled =
        put_in(snapshot.pending_delegations["d"][:context_wait], %{
          expired?: true,
          recheck_key: "5:number"
        })

      assert {:ok, [%{kind: :start_task, input: %{order: ^order}}]} =
               AppPolicy.interpret(settled, %ContextTrigger{},
                 classify: fn _ -> {:ok, %{intent: "status", order: order}} end
               )
    end
  end

  test "only extendable spoken numbers are delayed or reconstructed" do
    assert Speech.open_number?("order one hundred and twenty")
    assert Speech.open_number?("order eight hundred")
    assert Speech.open_number?("order one-twenty")
    refute Speech.open_number?("order one-twenty three")
    refute Speech.open_number?("order one-twenty.")
    assert Speech.completes_number?("Check order one-twenty", " three")
    refute Speech.completes_number?("Check order one-twenty.", " three")
    refute Speech.completes_number?("Check order one-twenty", " Actually, check 124")
    refute Speech.open_number?("order one hundred twenty four")
    refute Speech.open_number?("order one hundred twenty.")
    refute Speech.open_number?("check 124 and")
    assert Speech.completes_number?("Wait, items in order one hundred twenty", " four?")
    assert Speech.completes_number?("Wait, items in order one hundred", " twenty four")
    refute Speech.completes_number?("Check order one hundred twenty.", " four")
    refute Speech.completes_number?("Check one hundred twenty", " Actually, check 124")
    refute Speech.completes_number?("Check one hundred twenty", " What items are in that order?")
    refute Speech.completes_number?("Check one hundred twenty", " 124")
  end

  test "a correction's first digits cannot be filled from an earlier order" do
    for tail <- ["one", "one two", "1", "1 2", "one hundred", "one hundred twenty"] do
      snapshot = %ContextSnapshot{
        session_id: "short-number",
        transcripts: [
          %{speaker: :user, delta: "No, sorry. Go back to " <> tail, arrival_order: 5}
        ],
        tasks: %{
          "t" => %{revision: 2, input: %{order: "124", operation: "status", user_revision: 1}}
        }
      }

      assert {:ok, [%{kind: :wait_for_context, recheck_key: "5:number"}]} =
               AppPolicy.interpret(snapshot, %ContextTrigger{},
                 classify: fn _ -> flunk("Partial correction reached the classifier: #{tail}") end
               )
    end

    refute Speech.open_number?("No, sorry. Go back to one hundred twenty-three")
    refute Speech.open_number?("Check one two four")
    refute Speech.incomplete_number?("Are you still checking that one")
  end

  test "an unfinished short ID clarifies after settling instead of guessing an old target" do
    snapshot = %ContextSnapshot{
      session_id: "short-number",
      transcripts: [%{speaker: :user, delta: "Actually, order one two", arrival_order: 5}],
      tasks: %{
        "t" => %{
          revision: 1,
          input: %{order: "124", operation: "status", user_revision: 1},
          context_wait: %{recheck_key: "5:verify", expired?: true}
        }
      }
    }

    assert {:ok, [%{kind: :request_clarification, message: message}]} =
             AppPolicy.interpret(snapshot, %ContextTrigger{},
               classify: fn _ -> flunk("Incomplete ID must not resolve against history") end
             )

    assert message =~ "finish"
  end

  test "continued number resets admission and never submits intermediate 100 or 120" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order one hundred")
    event(:context_wait_started)
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 120
    ScriptedProvider.say(provider, " twenty")
    event(:context_wait_started)
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 120
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("one desk lamp", "1 Desk lamp")
    refute_receive {:context, _question}, 350
    assert_jobs(session, 2)
  end

  test "late completion reconstructs the request even after a prefix lookup finished" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order one hundred twenty")
    assert event(:task_submitted).payload.request.input.order == "120"
    context("Order 120 was not found")
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("one desk lamp", "1 Desk lamp")
    refute_receive {:context, _question}, 350
    assert_jobs(session, 3)
  end

  test "another partial extension also settles after a valid century lookup" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order one hundred")
    assert event(:task_submitted).payload.request.input.order == "100"
    context("Order 100 was not found")
    ScriptedProvider.say(provider, " twenty")
    event(:context_wait_started)
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 120
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("1 Desk lamp")
    refute_receive {:context, _question}, 350
    assert_jobs(session, 3)
  end

  test "uncertainty after number admission advances through recovery instead of restarting admission" do
    {_session, provider} = start(fn _ -> {:ok, %{intent: "items", order: "unknown"}} end)
    ScriptedProvider.say(provider, "Check one hundred twenty")
    ScriptedProvider.delegate(provider, "uncertain")
    context("Please clarify")
    refute_receive {:context, _duplicate}, 350
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 50
  end

  test "abbreviated correction waits for its tail instead of starting order 120" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order one-twenty")
    event(:context_wait_started)
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 120
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "short-correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("1 Desk lamp")
    refute_receive {:context, _question}, 350
    assert_jobs(session, 2)
  end

  test "late abbreviated tail reconstructs a completed prefix request" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order one-twenty")
    assert event(:task_submitted).payload.request.input.order == "120"
    context("Order 120 was not found")
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "short-late-correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("1 Desk lamp")
    event(:delegation_associated)
    assert_jobs(session, 3)
  end

  test "numeric cardinal prefixes and mixed continuations use the spoken-number rules" do
    for prefix <- ["100", "120", "990"] do
      assert Speech.open_number?("Check order " <> prefix)
    end

    for {text, expected} <- [
          {"120 three", "123"},
          {"100 twenty three", "123"},
          {"990 nine", "999"}
        ] do
      assert Speech.numbers(text) == [expected]
      refute Speech.incomplete_number?(text)
      refute Speech.open_number?(text)
    end

    assert Speech.open_number?("100 twenty")
    assert Speech.completes_number?("Check order 120", " three")
    assert Speech.completes_number?("Check order 100 twenty", " three")
    refute Speech.completes_number?("Check order 120.", " three")
    refute Speech.completes_number?("Check order 120", " Actually check 124")
    refute Speech.completes_number?("Check order 120", "\n three")
    refute "123" in Speech.numbers("120 3")
    refute "123" in Speech.numbers("120 three four")
    refute "140" in Speech.numbers("120 twenty")
  end

  test "numeric prefix waits and a prompt mixed tail avoids the intermediate lookup" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order 120")
    event(:context_wait_started)
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 120
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "numeric-correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("1 Desk lamp")
    refute_receive {:context, _question}, 350
    assert_jobs(session, 2)
  end

  test "numeric prefix can complete after a lookup without losing its spoken tail" do
    {session, provider} = start()
    first(provider)
    ScriptedProvider.say(provider, "\nWait, what items are in order 120")
    assert event(:task_submitted).payload.request.input.order == "120"
    context("Order 120 was not found")
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "numeric-late-correction")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("1 Desk lamp")
    event(:delegation_associated)
    assert_jobs(session, 3)
  end

  test "clarification reply is fresh even when old transcript segments overlap" do
    for {reply, expected, operation} <- [
          {" One hundred twenty three", "123", "status"},
          {" One two three", "123", "items"}
        ] do
      snapshot = %ContextSnapshot{
        session_id: "fresh-number-reply",
        transcripts: [
          %{speaker: :user, delta: reply, arrival_order: 9},
          %{speaker: :user, delta: " three", arrival_order: 5},
          %{speaker: :user, delta: "Sorry I mean 120", arrival_order: 3}
        ],
        tasks: %{
          "t" => %{
            revision: 1,
            status: :completed,
            input: %{order: "120", operation: operation, user_revision: 3},
            clarification: %{context_revision: 7}
          }
        },
        pending_delegations: %{"late" => %{status: :pending}}
      }

      assert {:ok, [%{kind: :supersede_task, input: input, delegation_id: "late"}]} =
               AppPolicy.interpret(snapshot, %ContextTrigger{},
                 classify: fn state ->
                   assert state.new_caller_text == reply

                   assert Map.take(state.clarification_reply, [:text, :previous_operation]) == %{
                            text: reply,
                            previous_operation: operation
                          }

                   assert expected in state.order_candidates
                   {:ok, %{intent: operation, order: expected}}
                 end
               )

      assert input.order == expected
      assert input.operation == operation
    end
  end

  test "pending delegation clarification also isolates the caller reply" do
    snapshot = %ContextSnapshot{
      session_id: "first-number-reply",
      transcripts: [
        %{speaker: :user, delta: "One two four", arrival_order: 5},
        %{speaker: :user, delta: "Check my order 10024", arrival_order: 1}
      ],
      pending_delegations: %{"d" => %{status: :pending, clarification: %{context_revision: 3}}}
    }

    assert {:ok, [%{kind: :start_task, input: %{order: "124"}}]} =
             AppPolicy.interpret(snapshot, %ContextTrigger{},
               classify: fn state ->
                 assert state.new_caller_text == "One two four"

                 assert Map.take(state.clarification_reply, [:text, :previous_operation]) == %{
                          text: "One two four",
                          previous_operation: nil
                        }

                 {:ok, %{intent: "status", order: "124"}}
               end
             )
  end

  test "a repeated number resolves recovery, claims delegations and delivers the corrected result" do
    owner = self()

    classifier = fn state ->
      if state.clarification_reply do
        send(owner, {:reply, state.clarification_reply})

        case Speech.numbers(state.clarification_reply.text) do
          [order] -> {:ok, %{intent: "items", order: order}}
          _ -> {:ok, %{intent: "items", order: "unknown"}}
        end
      else
        if state.new_caller_text =~ "huh",
          do: {:ok, %{intent: "items", order: "unknown"}},
          else: classify(state)
      end
    end

    {session, provider} = start(classifier)
    ScriptedProvider.say(provider, "What items are in order 120")
    ScriptedProvider.delegate(provider, "first")
    assert event(:task_submitted).payload.request.input.order == "120"
    context("Order 120 was not found")
    ScriptedProvider.say(provider, " huh")
    context("Please clarify")
    event(:clarification_requested)
    ScriptedProvider.say(provider, " One")
    event(:context_wait_started)
    ScriptedProvider.say(provider, " two")
    event(:context_wait_started)
    ScriptedProvider.say(provider, " four")
    ScriptedProvider.delegate(provider, "reply")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("1 Desk lamp")
    event(:delegation_associated)
    assert_receive {:reply, %{text: " One two four", previous_operation: "items"}}
    refute_receive {:context, _question}, 350
    assert_jobs(session, 2)
  end

  defp start(classify \\ &classify/1) do
    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           [
             classify: classify,
             number_settle_ms: 200,
             clarification_settle_ms: 100,
             clarification_verify_ms: 60
           ]}
      )

    on_exit(fn ->
      if Process.alive?(session), do: Parlora.close(session, :cancel)
      await_cleanup(System.monotonic_time(:millisecond) + 5_000)
    end)

    assert_receive {:scripted_provider, provider}
    event(:ready)
    {session, provider}
  end

  # Model-boundary fixture: a bare tail is ambiguous. The real live replay checks
  # that TypeSafe resolves the reconstructed full request as well.
  defp classify(state) do
    case Speech.numbers(state.new_caller_text) do
      [order] -> {:ok, %{intent: "items", order: order}}
      _ -> {:ok, %{intent: "items", order: "unknown"}}
    end
  end

  defp first(provider) do
    ScriptedProvider.say(provider, "What items are in order one hundred twenty three")
    ScriptedProvider.delegate(provider, "first")
    assert event(:task_submitted).payload.request.input.order == "123"
    context("Order 123 contains")
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      3_000 -> flunk("Missing event #{type}")
    end
  end

  defp context(text, alternate \\ nil) do
    receive do
      {:context, update} ->
        assert update.content =~ text or (alternate != nil and update.content =~ alternate)
    after
      3_000 -> flunk("Missing context #{text}")
    end
  end

  defp await_cleanup(deadline) do
    if DynamicSupervisor.count_children(Parlora.Sessions).active != 0 do
      assert System.monotonic_time(:millisecond) < deadline, "Session cleanup did not complete"
      Process.sleep(5)
      await_cleanup(deadline)
    end
  end

  defp assert_jobs(session, expected_count) do
    status = Parlora.status(session)
    assert map_size(status.jobs) == expected_count
    assert status.interpretation == :settled
    assert Enum.all?(status.delegations, fn {_, d} -> d.status == :claimed end)
    [task] = Map.values(Parlora.snapshot(session).tasks)
    assert task.input.order == "124"
    assert task.input.operation == "items"
  end
end
