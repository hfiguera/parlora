defmodule OrderDesk.PhoneConversationTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, Interpretation, ScriptedProvider, Speech, Store}
  alias Parlora.Event

  test "delivery extraction rejects dangling phrases and preserves a stated destination" do
    for text <- [
          "Leave it",
          "Leave it at",
          "Leave it at the",
          "Leave it with my",
          "Leave it at reception and"
        ] do
      assert Speech.delivery(text) == nil
    end

    assert Speech.delivery("change the delivery instructions and say left in the front desk") ==
             "left in the front desk"

    assert Speech.delivery("Leave it at reception") == "Leave it at reception"
    assert Speech.delivery("Leave it outside") == "Leave it outside"
    assert Speech.delivery("Deliver it tomorrow") == "Deliver it tomorrow"
    assert Speech.delivery("Actually, leave it with the neighbor") == "leave it with the neighbor"
    refute Speech.social?("Thanks, but check order 123")
    refute Speech.social?("Let me check order 123")
  end

  test "confident no-work intent does not require a confident order target" do
    assert {:ok, %{intent: "none"}} =
             Interpretation.interpret_answers(%{
               "intent" => %{choice: "none", probabilities: %{"none" => 0.95}},
               "target" => %{choice: "unknown", probabilities: %{"unknown" => 0.4}}
             })

    assert {:error, {:uncertain, %{uncertain_fields: ["intent"]}}} =
             Interpretation.interpret_answers(%{
               "intent" => %{choice: "none", probabilities: %{"none" => 0.6}},
               "target" => %{choice: "unknown", probabilities: %{"unknown" => 0.4}}
             })
  end

  test "fragmented draft waits for a complete stable destination and creates one proposal" do
    actor = Parlora.ID.new()
    {session, provider} = start(actor, fn _ -> {:ok, %{intent: "delivery", order: "124"}} end)
    ScriptedProvider.say(provider, "For order 124 leave it at")
    ScriptedProvider.delegate(provider, "draft")
    event(:context_wait_started)
    # Longer than the delivery settle interval: a dangling preposition is never a draft.
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 180
    assert Store.dashboard(actor).proposals == []
    ScriptedProvider.say(provider, " the front")
    event(:context_wait_started)
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 40
    ScriptedProvider.say(provider, " desk")
    request = event(:task_submitted).payload.request
    assert request.input.instructions == "leave it at the front desk"
    context("leave it at the front desk")
    assert [%{instructions: "leave it at the front desk"}] = Store.dashboard(actor).proposals
    assert map_size(Parlora.status(session).jobs) == 1
  end

  test "social replies after pending recovery settle without reopening the old request" do
    {session, provider} =
      start(Parlora.ID.new(), fn state ->
        if state.latest_caller_segment =~ "another order",
          do: {:error, :uncertain},
          else: {:ok, %{intent: "status", order: "124"}}
      end)

    say(provider, :user, "Check order 124", 0)
    ScriptedProvider.delegate(provider, "status")
    event(:task_submitted)
    context("out for delivery")
    say(provider, :assistant, "It is out for delivery", 1_000)
    say(provider, :user, "Check another order", 2_000)
    event(:context_wait_started)
    say(provider, :assistant, "Go ahead", 3_000)
    say(provider, :user, "Let me check", 4_000)
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 800
    assert Parlora.status(session).interpretation == :settled
    say(provider, :assistant, "Okay", 5_000)
    say(provider, :user, "Okay, thank you. Bye", 6_000)
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 800
    assert Parlora.status(session).interpretation == :settled
    assert map_size(Parlora.status(session).jobs) == 1
  end

  test "instruction query reads saved data without creating a draft" do
    actor = Parlora.ID.new()
    {:ok, before_order} = Store.order("124")
    {session, provider} = start(actor, fn _ -> {:ok, %{intent: "instructions", order: "124"}} end)
    ScriptedProvider.say(provider, "Any delivery instructions for order 124?")
    ScriptedProvider.delegate(provider, "instructions")
    assert event(:task_submitted).payload.request.input.operation == "instructions"
    context("Saved delivery instructions for order 124")
    assert Store.dashboard(actor).proposals == []
    assert {:ok, ^before_order} = Store.order("124")
    assert map_size(Parlora.status(session).jobs) == 1
  end

  defp start(actor, classify) do
    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{actor: actor},
        context_policy:
          {AppPolicy,
           classify: classify,
           delivery_settle_ms: 120,
           clarification_settle_ms: 300,
           clarification_verify_ms: 150}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    {session, provider}
  end

  defp say(provider, speaker, delta, at),
    do:
      ScriptedProvider.transcript(provider, %{
        speaker: speaker,
        delta: delta,
        start_ms: at,
        end_ms: at + 500
      })

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = e} -> e
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
