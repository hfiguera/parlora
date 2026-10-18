defmodule OrderDesk.RefusalTest do
  use ExUnit.Case
  alias OrderDesk.{ScriptedProvider, Store}
  alias Parlora.Event

  test "spoken refusal rejects the exact draft, prevents confirmation, and leaves orders unchanged" do
    actor = Parlora.ID.new()
    {:ok, before_order} = Store.order("124")
    {:ok, _} = Store.propose(actor, "123", "other draft", "other-" <> actor)
    {session, provider} = start(actor)
    ScriptedProvider.say(provider, "For order 124 leave it at reception")
    ScriptedProvider.delegate(provider, "draft")
    first = event(:task_submitted).payload.request
    context("A draft for order 124")
    ScriptedProvider.say(provider, " Don't save that")
    second = event(:task_submitted).payload.request
    assert second.input.proposal_id == first.id
    context("was rejected")
    assert {:error, :conflict} = Store.confirm(actor, first.id)
    assert {:ok, ^before_order} = Store.order("124")
    assert Enum.find(Store.dashboard(actor).proposals, &(&1.id == first.id)).status == "rejected"
    assert Enum.find(Store.dashboard(actor).proposals, &(&1.order == "123")).status == "pending"
    ScriptedProvider.delegate(provider, "late-refusal")
    event(:delegation_associated)
    ScriptedProvider.say(provider, " Don't save that")
    refute_receive {:context, _duplicate}, 300
    assert map_size(Parlora.status(session).jobs) == 2
    assert Parlora.status(session).interpretation == :settled
  end

  test "refusal during creation prevents a delayed job from resurrecting the draft" do
    actor = Parlora.ID.new()
    Application.put_env(:order_desk, :lookup_delays, %{"124" => 250})
    on_exit(fn -> Application.delete_env(:order_desk, :lookup_delays) end)
    {_session, provider} = start(actor)
    ScriptedProvider.say(provider, "For order 124 leave it at reception")
    ScriptedProvider.delegate(provider, "draft")
    first = event(:task_submitted).payload.request
    Application.delete_env(:order_desk, :lookup_delays)
    ScriptedProvider.say(provider, " Don't save that")
    event(:task_submitted)
    context("was rejected")
    event(:stale_result)
    [draft] = Store.dashboard(actor).proposals
    assert draft.id == first.id and draft.status == "rejected"
    assert {:error, :conflict} = Store.confirm(actor, first.id)
  end

  test "refusal is actor-bound, idempotent and cannot undo a confirmed update" do
    db = start_supervised!({Store, name: nil, path: ":memory:"})
    {:ok, _} = Store.propose("actor", "124", "reception", "id", db)
    assert {:error, :not_found} = Store.refuse("stranger", "124", "id", db)
    assert {:ok, _} = Store.confirm("actor", "id", db)
    assert {:error, :already_applied} = Store.refuse("actor", "124", "id", db)
    assert {:ok, %{instructions: "reception", version: 2}} = Store.order("124", db)
    assert {:ok, :rejected} = Store.refuse("actor", "124", "not-created-yet", db)
    assert {:ok, :rejected} = Store.refuse("actor", "124", "not-created-yet", db)
    assert {:error, :rejected} = Store.propose("actor", "124", "late text", "not-created-yet", db)
    assert {:error, :conflict} = Store.confirm("actor", "not-created-yet", db)
    assert length(Store.dashboard("actor", db).changes) == 1
  end

  defp start(actor) do
    classify = fn state ->
      intent = if state.caller_history =~ "Don't save", do: "refuse", else: "delivery"
      if intent == "refuse", do: assert(Enum.any?(state.delivery_drafts, &(&1.order == "124")))
      {:ok, %{intent: intent, order: "124"}}
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{actor: actor},
        context_policy: {OrderDesk.AppPolicy, classify: classify}
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
      2_000 -> flunk("Missing #{type}")
    end
  end

  defp context(fragment) do
    receive do
      {:context, update} -> assert update.content =~ fragment
    after
      2_000 -> flunk("Missing #{fragment}")
    end
  end
end
