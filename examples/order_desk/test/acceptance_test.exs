defmodule OrderDesk.AcceptanceTest do
  use ExUnit.Case
  alias OrderDesk.{ScriptedProvider, Store}
  alias Parlora.Event

  setup do
    previous = Application.get_env(:order_desk, :lookup_delays)
    Application.put_env(:order_desk, :lookup_delays, %{"123" => 300, "124" => 120})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:order_desk, :lookup_delays, previous),
        else: Application.delete_env(:order_desk, :lookup_delays)
    end)

    %{actor: Parlora.ID.new()}
  end

  test "1 correct the order repeatedly", %{actor: actor} do
    {s, p} = start(actor)
    ask(p, "Check order 123.", "a")
    first = event(:task_submitted).payload.request
    ask(p, "Actually, I meant 124.", "b")
    second = event(:task_submitted).payload.request
    await(fn -> Parlora.status(s).delegations["b"].status == :claimed end)
    ask(p, "No, sorry, go back to 123.", "c")
    third = event(:task_submitted).payload.request
    assert {first.input.order, second.input.order, third.input.order} == {"123", "124", "123"}
    assert first.task_id == third.task_id
    assert third.task_revision == 3
    settled(s, 3)
    jobs = Parlora.status(s).jobs
    assert jobs[third.id].delivery == :accepted
    assert jobs[second.id].delivery == :stale
    assert jobs[first.id].delivery == :stale
    context("Order 123 is")
  end

  test "2 leave out the order number", %{actor: actor} do
    {s, p} = start(actor)
    ask(p, "Can you check my order?", "missing")
    event(:clarification_requested)
    assert Parlora.status(s).jobs == %{}
    context("three-digit order number")
    ScriptedProvider.say(p, "\nOne two four.")
    assert event(:task_submitted).payload.request.input.order == "124"
    context("out for delivery")
    settled(s, 1)
  end

  test "3 ask about different things", %{actor: actor} do
    {s, p} = start(actor)
    ask(p, "Check order 124.", "status")
    first = event(:task_submitted).payload.request
    context("out for delivery")
    ask(p, "What items are in that order?", "items")
    second = event(:task_submitted).payload.request
    assert second.input.operation == "items" and second.input.order == "124"
    refute first.task_id == second.task_id
    context("1 Desk lamp")
    settled(s, 2)
  end

  test "4 create a delivery draft then refuse", %{actor: actor} do
    {:ok, before} = Store.order("124")
    {s, p} = start(actor)
    ask(p, "For order 124, leave it at reception.", "draft")
    draft = event(:task_submitted).payload.request
    context("Nothing has been changed")
    ScriptedProvider.say(p, "\nNo, don't save that.")
    event(:task_submitted)
    context("was rejected")
    ScriptedProvider.delegate(p, "refusal")
    settled(s, 2)
    assert {:ok, ^before} = Store.order("124")
    assert {:error, :conflict} = Store.confirm(actor, draft.id)
    assert Enum.find(Store.dashboard(actor).proposals, &(&1.id == draft.id)).status == "rejected"
  end

  test "5 correct delivery instructions", %{actor: actor} do
    {:ok, before} = Store.order("124")
    {s, p} = start(actor)
    ask(p, "For order 124, leave the package at reception.", "reception")
    first = event(:task_submitted).payload.request
    context("Nothing has been changed")
    ask(p, "Actually, leave it with the neighbor.", "neighbor")
    second = event(:task_submitted).payload.request
    context("Nothing has been changed")
    settled(s, 2)
    assert {:ok, ^before} = Store.order("124")
    drafts = Store.dashboard(actor).proposals

    assert Enum.find(drafts, &(&1.id == first.id)).instructions ==
             "leave the package at reception"

    assert Enum.find(drafts, &(&1.id == second.id)).instructions == "leave it with the neighbor"
    assert :ok = Store.reject(actor, first.id)
    assert {:ok, %{version: version}} = Store.confirm(actor, second.id)
    assert version == before.version + 1
    assert {:ok, %{duplicate: true}} = Store.confirm(actor, second.id)

    assert {:ok, %{instructions: "leave it with the neighbor", version: ^version}} =
             Store.order("124")
  end

  test "6 interrupt and disconnect", %{actor: actor} do
    id = Parlora.ID.new()
    {:ok, _} = Store.propose(actor, "124", "persisted acceptance instruction", id)
    {:ok, _} = Store.confirm(actor, id)
    pending = Parlora.ID.new()
    {:ok, _} = Store.propose(actor, "123", "pending acceptance instruction", pending)
    before = Store.dashboard(actor)
    Application.put_env(:order_desk, :lookup_delays, %{"123" => 300, "124" => 2_000})
    {s, p} = start(actor)
    ask(p, "What items are in order 123?", "first")
    event(:task_submitted)
    # Overlapping transcript intervals exercise context handling; acoustic barge-in
    # is covered only by the opt-in browser suite.
    ScriptedProvider.transcript(p, %{
      speaker: :assistant,
      delta: "Checking",
      start_ms: 0,
      end_ms: 100
    })

    ask(p, "Wait, what items are in order 124?", "interrupt")
    request = event(:task_submitted).payload.request
    await(fn -> Map.get(Parlora.status(s).jobs[request.id], :started_at_us) != nil end)
    assert Parlora.status(s).jobs[request.id].status == :submitted
    old_id = Parlora.status(s).session_id
    close(s)
    {fresh, provider} = start(actor)
    assert Parlora.status(fresh).session_id != old_id
    assert Parlora.status(fresh).jobs == %{}
    assert Parlora.status(fresh).delegations == %{}
    assert Store.dashboard(actor) == before
    Application.put_env(:order_desk, :lookup_delays, %{})
    ask(provider, "What items are in order 124?", "fresh")
    event(:task_submitted)
    context("1 Desk lamp")
    settled(fresh, 1)
  end

  defp classify(state) do
    text = String.downcase(state.new_caller_text)

    intent =
      cond do
        text =~ "don't save" -> "refuse"
        text =~ "leave" -> "delivery"
        text =~ "items" -> "items"
        true -> "status"
      end

    order =
      List.last(OrderDesk.Speech.numbers(text)) ||
        (state.active_task && state.active_task.order) || List.last(state.order_candidates) ||
        "unknown"

    {:ok, %{intent: intent, order: order}}
  end

  defp start(actor) do
    {:ok, s} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{actor: actor},
        context_policy:
          {OrderDesk.AppPolicy,
           classify: &classify/1, clarification_settle_ms: 60, clarification_verify_ms: 40}
      )

    on_exit(fn -> close(s) end)
    assert_receive {:scripted_provider, p}
    event(:ready)
    {s, p}
  end

  defp ask(p, text, id) do
    ScriptedProvider.say(p, "\n" <> text)
    ScriptedProvider.delegate(p, id)
  end

  defp settled(s, count) do
    await(fn ->
      status = Parlora.status(s)

      map_size(status.jobs) == count and status.interpretation == :settled and
        Enum.all?(status.jobs, fn {_, j} ->
          j.status == :completed and j.delivery in [:accepted, :stale]
        end) and
        Enum.all?(status.delegations, fn {_, d} -> d.status == :claimed end)
    end)
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = e} -> e
    after
      5_000 -> flunk("Missing event #{type}")
    end
  end

  defp context(text) do
    receive do
      {:context, update} -> if update.content =~ text, do: :ok, else: context(text)
    after
      5_000 -> flunk("Missing context #{text}")
    end
  end

  defp close(s) do
    if Process.alive?(s), do: Parlora.close(s, :cancel)
    await(fn -> DynamicSupervisor.count_children(Parlora.Sessions).active == 0 end)
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 5_000)

  defp await(fun, deadline) do
    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline, "Acceptance condition timed out"
      Process.sleep(10)
      await(fun, deadline)
    end
  end
end
