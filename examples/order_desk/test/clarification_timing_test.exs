defmodule OrderDesk.ClarificationTimingTest do
  use ExUnit.Case
  alias OrderDesk.ScriptedProvider
  alias Parlora.Event

  defp start(classify, options \\ []) do
    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {OrderDesk.AppPolicy,
           Keyword.merge(
             [classify: classify, clarification_settle_ms: 120, clarification_verify_ms: 60],
             options
           )}
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
      {:context, update} ->
        assert update.content =~ fragment
        update
    after
      2_000 -> flunk("Missing provider context #{fragment}")
    end
  end

  defp start_orders(provider) do
    ScriptedProvider.say(provider, "Check order 123")
    ScriptedProvider.delegate(provider, "first")
    event(:task_submitted)
    context("Order 123 is")
    ScriptedProvider.say(provider, " Actually I mean 124")
    event(:task_submitted)
    context("Order 124 is")
  end

  defp answer(text, resolve?) do
    cond do
      String.contains?(text, "No sorry") ->
        if resolve?, do: {:ok, %{intent: "status", order: "123"}}, else: {:error, :uncertain}

      String.contains?(text, "Actually") ->
        {:ok, %{intent: "status", order: "124"}}

      true ->
        {:ok, %{intent: "status", order: "123"}}
    end
  end

  test "continuing correction replaces the old wait and resolves without a question" do
    classify = fn %{caller_history: text} ->
      answer(text, String.ends_with?(text, "back to 123"))
    end

    {session, provider} = start(classify)
    start_orders(provider)
    ScriptedProvider.say(provider, " No sorry")
    event(:context_wait_started)
    [{id, task}] = Map.to_list(Parlora.snapshot(session).tasks)
    due = task.context_wait.due_at_us
    Process.sleep(80)
    ScriptedProvider.say(provider, ", go back to")
    event(:context_wait_started)
    assert Parlora.snapshot(session).tasks[id].context_wait.due_at_us > due
    Process.sleep(80)
    ScriptedProvider.say(provider, " 123")
    third = event(:task_submitted).payload.request
    assert third.input.order == "123"
    assert third.task_revision == 3
    context("Order 123 is")
    refute_receive {:context, _question}, 250
  end

  test "temporarily uncertain complete correction gets a verification recheck before clarification" do
    resolved = :atomics.new(1, [])

    {session, provider} =
      start(fn %{caller_history: text} -> answer(text, :atomics.get(resolved, 1) == 1) end)

    start_orders(provider)
    ScriptedProvider.say(provider, " No sorry, go back to 123")
    event(:context_wait_started)
    event(:context_wait_started)
    [task] = Map.values(Parlora.snapshot(session).tasks)
    assert String.ends_with?(task.context_wait.recheck_key, ":verify")
    :atomics.put(resolved, 1, 1)
    assert event(:task_submitted).payload.request.input.order == "123"
    context("Order 123 is")
    refute_receive {:context, _question}, 250
  end

  test "genuine ambiguity asks once and does not flip to an answer without a caller reply" do
    resolved = :atomics.new(1, [])

    classify = fn _ ->
      if :atomics.get(resolved, 1) == 1,
        do: {:ok, %{intent: "status", order: "123"}},
        else: {:error, :uncertain}
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check my order")
    ScriptedProvider.delegate(provider, "missing")
    context("Please clarify")
    event(:clarification_requested)
    :atomics.put(resolved, 1, 1)
    # A changed judgment on the same caller input must not contradict a question already sent.
    Parlora.update_context(session, %{unrelated: true})
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 150
    refute_receive {:context, _duplicate}, 100
    ScriptedProvider.say(provider, " 123")
    assert event(:task_submitted).payload.request.input.order == "123"
    context("Order 123 is")
  end

  test "new input invalidates a verification in flight before it can ask the obsolete question" do
    owner = self()
    attempts = :atomics.new(1, [])

    classify = fn %{caller_history: text} ->
      if text == "Check my order" and :atomics.add_get(attempts, 1, 1) == 3 do
        send(owner, {:verifying, self()})
        receive do: (:release -> :ok)
      end

      if String.ends_with?(text, " 124"),
        do: {:ok, %{intent: "status", order: "124"}},
        else: {:error, :uncertain}
    end

    {session, provider} = start(classify)
    ScriptedProvider.say(provider, "Check my order")
    ScriptedProvider.delegate(provider, "in-flight")
    assert_receive {:verifying, worker}, 1_500
    before = Parlora.snapshot(session).revision
    ScriptedProvider.say(provider, " 124")
    assert Parlora.snapshot(session).revision > before
    send(worker, :release)
    assert event(:task_submitted).payload.request.input.order == "124"
    context("Order 124 is")
    refute_receive {:context, _obsolete_question}, 200
  end

  test "interpreter outage still yields one bounded recovery message without speculative jobs" do
    {_session, provider} = start(fn _ -> {:error, :timeout} end)
    ScriptedProvider.say(provider, "Check 124")
    ScriptedProvider.delegate(provider, "outage")
    context("interpreter is unavailable")
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 100
  end

  test "verification bypasses a cached uncertain or unavailable judgment" do
    input = %{probe: Parlora.ID.new()}
    before = OrderDesk.Interpretation.stats()
    assert {:error, :unavailable} = OrderDesk.Interpretation.classify(input)
    assert {:error, :unavailable} = OrderDesk.Interpretation.classify(input)
    assert OrderDesk.Interpretation.stats().calls == before.calls + 1
    assert {:error, :unavailable} = OrderDesk.Interpretation.classify(input, fresh?: true)
    assert OrderDesk.Interpretation.stats().calls == before.calls + 2
  end

  test "a temporarily uncertain number-only reply gets a fresh timed recheck" do
    attempts = :atomics.new(1, [])

    {session, provider} =
      start(fn state ->
        if state.order_candidates == ["124"] and :atomics.add_get(attempts, 1, 1) > 1,
          do: {:ok, %{intent: "status", order: "124"}},
          else: {:error, :uncertain}
      end)

    ScriptedProvider.say(provider, "Check my order")
    ScriptedProvider.delegate(provider, "missing")
    context("Please clarify")
    event(:clarification_requested)
    ScriptedProvider.say(provider, " One, two, four")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("Order 124 is")
    assert map_size(Parlora.snapshot(session).tasks) == 1
    refute_receive {:context, _duplicate_question}, 250
  end

  test "another unresolved reply receives one new question and a later valid number resolves" do
    {_session, provider} =
      start(fn state ->
        if state.order_candidates == ["124"],
          do: {:ok, %{intent: "status", order: "124"}},
          else: {:error, :uncertain}
      end)

    ScriptedProvider.say(provider, "Check my order")
    ScriptedProvider.delegate(provider, "missing")
    first = context("Please clarify")
    event(:clarification_requested)
    ScriptedProvider.say(provider, " I cannot remember")
    second = context("Please clarify")
    event(:clarification_requested)
    refute first.id == second.id
    refute_receive {:context, _duplicate_question}, 250
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 50
    ScriptedProvider.say(provider, " One hundred twenty four")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("Order 124 is")
  end
end
