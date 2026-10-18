defmodule OrderDesk.FollowupTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, Interpretation, ScriptedProvider}
  alias Parlora.{ContextSnapshot, ContextTrigger, Event}

  defp answer(choice, probability), do: %{choice: choice, probabilities: %{choice => probability}}

  test "classifier offers follow-up only when previous work exists" do
    fresh = %{order_candidates: ["124"], active_task: nil, recent_work: []}
    question = Interpretation.questions(fresh)["intent"]
    refute Map.has_key?(question.criteria, "lookup_progress")
    assert Map.has_key?(question.criteria, "order_status")
    assert Map.has_key?(question.criteria, "unclear")
    assert Map.has_key?(Interpretation.questions(fresh)["target"].criteria, "unknown")

    task = %{operation: "items", order: "124", status: :completed}

    for state <- [%{fresh | active_task: task}, %{fresh | recent_work: [task]}] do
      assert Map.has_key?(Interpretation.questions(state)["intent"].criteria, "lookup_progress")
    end
  end

  test "completed lookup ignores punctuation tails but still handles corrections and ambiguity" do
    owner = self()

    classify = fn state ->
      cond do
        Regex.match?(~r/^[\s\p{P}]*$/u, state.new_caller_text) ->
          send(owner, :classified_punctuation)
          {:error, {:uncertain, %{intent: "none", order: "123", uncertain_fields: ["intent"]}}}

        state.new_caller_text =~ "another order" ->
          {:ok, %{intent: "status", order: "unknown"}}

        state.caller_history =~ "124" ->
          {:ok, %{intent: "status", order: "124"}}

        true ->
          {:ok, %{intent: "status", order: "123"}}
      end
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check order 123")
    ScriptedProvider.delegate(provider, "lookup")
    event(:task_submitted)
    context("expected Friday")
    await_settled(session)
    for tail <- [".", " ", "—", "\n"], do: ScriptedProvider.say(provider, tail)
    await_settled(session)
    refute_receive :classified_punctuation, 350
    refute_received {:parlora_event, %Event{type: :clarification_requested}}
    refute_received {:context, _question}
    assert map_size(Parlora.status(session).jobs) == 1

    # A late delegation can still associate with the existing lookup.
    ScriptedProvider.delegate(provider, "late-lookup")
    event(:delegation_associated)
    await_settled(session)

    ScriptedProvider.say(provider, "Actually 124")
    event(:task_submitted)
    context("out for delivery")
    await_settled(session)
    assert map_size(Parlora.status(session).jobs) == 2

    ScriptedProvider.say(provider, "Actually another order")
    context("three-digit")
    event(:clarification_requested)
    assert Parlora.status(session).interpretation == :unresolved
    assert map_size(Parlora.status(session).jobs) == 2
  end

  test "uncertainty retains which judgment failed without lowering the threshold" do
    assert {:error, {:uncertain, %{order: "124", uncertain_fields: ["intent"]}}} =
             Interpretation.interpret_answers(%{
               "intent" => answer("status", 0.63),
               "target" => answer("124", 0.97)
             })

    assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
             Interpretation.interpret_answers(%{
               "intent" => answer("followup", 0.95),
               "target" => answer("124", 0.6)
             })

    assert {:ok, %{intent: "followup", order: "124"}} =
             Interpretation.interpret_answers(%{
               "intent" => answer("followup", 0.8),
               "target" => answer("124", 0.8)
             })
  end

  test "operation ambiguity asks about the request, while target ambiguity asks about the order" do
    task = %{
      revision: 1,
      status: :completed,
      input: %{order: "124", operation: "items", user_revision: 1},
      context_wait: %{expired?: true, recheck_key: "5:verify"}
    }

    snapshot = %ContextSnapshot{
      session_id: "followup",
      tasks: %{"items" => task},
      transcripts: [%{speaker: :user, delta: "do you check my order", arrival_order: 5}]
    }

    for {fields, expected} <- [
          {["intent"], "Do you mean the delivery status for order 124?"},
          {["target"], "three-digit"}
        ] do
      assert {:ok, [%{kind: :request_clarification, message: message}]} =
               AppPolicy.interpret(snapshot, %ContextTrigger{},
                 classify: fn _ ->
                   {:error,
                    {:uncertain, %{intent: "status", order: "124", uncertain_fields: fields}}}
                 end
               )

      assert message =~ expected
      if fields == ["intent"], do: refute(message =~ "three-digit")
    end
  end

  test "status then items then follow-up settles without another lookup or clarification" do
    owner = self()

    classify = fn state ->
      cond do
        state.caller_history =~ "do you check" ->
          send(owner, {:followup_input, state})
          {:ok, %{intent: "followup", order: "124"}}

        state.caller_history =~ "What items" ->
          {:ok, %{intent: "items", order: "124"}}

        true ->
          {:ok, %{intent: "status", order: "124"}}
      end
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check order one hundred twenty four")
    ScriptedProvider.delegate(provider, "status")
    event(:task_submitted)
    context("out for delivery")
    ScriptedProvider.say(provider, " What items are in that order")
    ScriptedProvider.delegate(provider, "items")
    items = event(:task_submitted).payload.request
    context("Desk lamp")
    ScriptedProvider.say(provider, " Okay, and do you check in my order")
    assert_receive {:followup_input, input}, 1_000
    assert input.active_task == %{order: "124", operation: "items", status: :completed}
    assert input.new_caller_text == " Okay, and do you check in my order"

    assert Enum.map(input.recent_work, &{&1.operation, &1.status}) == [
             {"items", :completed},
             {"status", :completed}
           ]

    await_settled(session)
    # A late delegation for this follow-up claims the existing task, without new work.
    ScriptedProvider.delegate(provider, "followup")
    assert event(:delegation_associated).payload.task_id == items.task_id
    await_settled(session)
    progress = Parlora.status(session)
    assert map_size(progress.jobs) == 2

    assert Enum.all?(progress.jobs, fn {_, job} ->
             job.status == :completed and job.delivery == :accepted
           end)

    assert Enum.all?(progress.delegations, fn {_, delegation} -> delegation.status == :claimed end)

    refute_receive {:context, _clarification}, 350
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 50
  end

  test "ambiguous follow-up clarifies the operation on the current order without dispatching work" do
    classify = fn state ->
      cond do
        state.new_caller_text =~ "item's list" ->
          {:ok, %{intent: "items", order: "124"}}

        state.new_caller_text =~ "Do you know" ->
          {:error,
           {:uncertain,
            %{intent: "unclear", order: "124", uncertain_fields: ["intent", "target"]}}}

        true ->
          {:ok, %{intent: "status", order: "124"}}
      end
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check order 124")
    ScriptedProvider.delegate(provider, "status")
    event(:task_submitted)
    context("out for delivery")
    ScriptedProvider.say(provider, " Do you know what it is order")
    ScriptedProvider.delegate(provider, "ambiguous")
    context("For order 124")
    event(:clarification_requested)
    assert map_size(Parlora.status(session).jobs) == 1
    assert Parlora.status(session).interpretation == :unresolved
    refute_receive {:context, _duplicate}, 100

    # The caller only needs to clarify the operation, without repeating 124.
    ScriptedProvider.say(provider, " The item's list")
    request = event(:task_submitted).payload.request
    assert request.input.order == "124"
    assert request.input.operation == "items"
    context("Desk lamp")
    await_settled(session)
    assert map_size(Parlora.status(session).jobs) == 2
  end

  test "contextual clarification never borrows an order for changed, unknown, or ambiguous targets" do
    task = %{
      revision: 1,
      status: :completed,
      input: %{order: "124", operation: "status", user_revision: 1},
      context_wait: %{expired?: true, recheck_key: "3:verify"}
    }

    for {text, target} <- [
          {"What is in another order", "124"},
          {"What about a different one", "124"},
          {"Go back to the previous order", "124"},
          {"No, not that order", "124"},
          {"What is in order 123", "124"},
          {"What is in order 123 or 124", "124"},
          {"Do you know what it is order", "unknown"},
          {"Do you know what it is order", "123"}
        ] do
      snapshot = %ContextSnapshot{
        session_id: "guard",
        tasks: %{"current" => task},
        transcripts: [%{speaker: :user, delta: text, arrival_order: 3}]
      }

      assert {:ok, [%{kind: :request_clarification} = question]} =
               AppPolicy.interpret(snapshot, %ContextTrigger{},
                 classify: fn _ ->
                   {:error,
                    {:uncertain,
                     %{intent: "unclear", order: target, uncertain_fields: ["intent", "target"]}}}
                 end
               )

      assert question.input.known_order == nil

      if text == "What is in order 123" do
        assert question.input.candidate_order == "123"
        assert question.message =~ "Do you mean order 123?"
        refute question.message =~ "124"
      else
        refute Map.has_key?(question.input, :candidate_order)
        assert question.message =~ "three-digit"
      end
    end
  end

  test "a follow-up about running work keeps it running and allows its result through" do
    Application.put_env(:order_desk, :lookup_delays, %{"124" => 300})
    on_exit(fn -> Application.delete_env(:order_desk, :lookup_delays) end)

    {session, provider} =
      start(fn state ->
        intent = if state.caller_history =~ "Still checking", do: "followup", else: "status"
        {:ok, %{intent: intent, order: "124"}}
      end)

    ScriptedProvider.say(provider, "Check order 124")
    ScriptedProvider.delegate(provider, "running")
    event(:task_submitted)
    ScriptedProvider.say(provider, " Still checking?")
    context("out for delivery")
    await_settled(session)
    assert map_size(Parlora.status(session).jobs) == 1
    refute_receive {:context, _clarification}, 250
  end

  test "order-status and lookup-progress labels normalize without relaxing confidence" do
    for {label, expected} <- [{"order_status", "status"}, {"lookup_progress", "followup"}] do
      assert {:ok, %{intent: ^expected, order: "124"}} =
               Interpretation.interpret_answers(%{
                 "intent" => answer(label, 0.9),
                 "target" => answer("124", 0.96)
               })

      assert {:error, {:uncertain, %{uncertain_fields: ["intent"]}}} =
               Interpretation.interpret_answers(%{
                 "intent" => answer(label, 0.66),
                 "target" => answer("124", 0.96)
               })

      assert {:error, {:uncertain, %{uncertain_fields: ["target"]}}} =
               Interpretation.interpret_answers(%{
                 "intent" => answer(label, 0.95),
                 "target" => answer("unknown", 0.6)
               })
    end
  end

  test "status question after items settles even when the provider answers before delegation" do
    classify = fn state ->
      label =
        cond do
          state.new_caller_text =~ "what is the status" -> "order_status"
          state.new_caller_text =~ "item list" -> "items"
          true -> "order_status"
        end

      Interpretation.interpret_answers(%{
        "intent" => answer(label, 0.95),
        "target" => answer("124", 0.98)
      })
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check order 124")
    ScriptedProvider.delegate(provider, "status-initial")
    event(:task_submitted)
    context("out for delivery")
    ScriptedProvider.say(provider, " No, I mean the item list")
    ScriptedProvider.delegate(provider, "items")
    event(:task_submitted)
    context("Desk lamp")

    ScriptedProvider.say(provider, " Okay, and what is the status?")

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "It is out for delivery.",
      start_ms: 200,
      end_ms: 600
    })

    # Exceed the configured settle + verification windows. An already spoken
    # answer must not be followed by an application-generated clarification.
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 450
    await_settled(session)
    assert map_size(Parlora.status(session).jobs) == 3

    # The understood refresh starts immediately, anchored to the items task.
    # A later delegation associates with that refresh without executing it again.
    request = event(:task_submitted).payload.request
    assert request.delegation_id == nil
    ScriptedProvider.delegate(provider, "status-refresh")
    assert request.input.operation == "status"
    assert request.input.order == "124"
    context("out for delivery")
    event(:delegation_associated)
    await_settled(session)
    assert map_size(Parlora.status(session).jobs) == 3
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 100
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 300
  end

  test "answered progress remains context when a new items lookup follows" do
    owner = self()

    classify = fn state ->
      cond do
        state.latest_caller_segment =~ "What items" ->
          send(owner, {:items_input, state})
          {:ok, %{intent: "items", order: "124"}}

        state.latest_caller_segment =~ "Do you check it" ->
          {:ok, %{intent: "followup", order: "124"}}

        true ->
          {:ok, %{intent: "status", order: "124"}}
      end
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check order 124")
    ScriptedProvider.delegate(provider, "status")
    event(:task_submitted)
    context("out for delivery")

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Order 124 is out for delivery."
    })

    ScriptedProvider.say(provider, "Do you check it")
    await_settled(session)
    ScriptedProvider.transcript(provider, %{speaker: :assistant, delta: "Yes, I did."})
    ScriptedProvider.say(provider, "What items are there?")
    assert_receive {:items_input, input}, 1_000
    assert input.new_caller_text =~ "Do you check it"
    assert input.new_caller_text =~ "What items"

    assert Enum.take(input.recent_dialogue, -3) == [
             %{speaker: :user, text: "Do you check it"},
             %{speaker: :assistant, text: "Yes, I did."},
             %{speaker: :user, text: "What items are there?"}
           ]

    assert input.active_task.operation == "status"
    request = event(:task_submitted).payload.request
    assert request.input.operation == "items"
    assert request.input.order == "124"
    context("Desk lamp")
    ScriptedProvider.delegate(provider, "items-late")
    event(:delegation_associated)
    await_settled(session)
    assert map_size(Parlora.status(session).jobs) == 2
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 300
  end

  defp start(classify) do
    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           classify: classify, clarification_settle_ms: 120, clarification_verify_ms: 60}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    {session, provider}
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      2_000 -> flunk("Missing event #{type}")
    end
  end

  defp context(fragment) do
    receive do
      {:context, update} -> assert update.content =~ fragment
    after
      2_000 -> flunk("Missing provider context #{fragment}")
    end
  end

  defp await_settled(session, attempts \\ 100)
  defp await_settled(_session, 0), do: flunk("Interpretation did not settle")

  defp await_settled(session, attempts) do
    if Parlora.status(session).interpretation != :settled do
      Process.sleep(10)
      await_settled(session, attempts - 1)
    end
  end
end
