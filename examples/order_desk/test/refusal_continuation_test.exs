defmodule OrderDesk.RefusalContinuationTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider, Store}
  alias Parlora.Event

  test "late refusal fragment after acknowledgment stays settled, but new requests still work" do
    owner = self()

    classify = fn state ->
      send(owner, {:classified, state})

      cond do
        state.new_caller_text =~ "Check another order" ->
          {:error,
           {:uncertain, %{intent: "status", order: "unknown", uncertain_fields: ["target"]}}}

        state.new_caller_text =~ "What items" ->
          {:ok, %{intent: "items", order: "123"}}

        state.new_caller_text == "'that" ->
          # Reproduces the real classifier's dependence on the unfinished handled input.
          if state.handled_caller_input == "No! Don't say the",
            do: {:ok, %{intent: "refuse", order: "124"}},
            else: {:error, :uncertain}

        state.new_caller_text =~ "Don't say" ->
          {:ok, %{intent: "refuse", order: "124"}}

        true ->
          {:ok, %{intent: "delivery", order: "124"}}
      end
    end

    actor = Parlora.ID.new()
    {:ok, original} = Store.order("124")

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context: %{actor: actor},
        context_policy: {AppPolicy, classify: classify}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    say(provider, :user, "For order 124 leave it at reception", 0, 1_000)
    ScriptedProvider.delegate(provider, "draft")
    draft = event(:task_submitted).payload.request
    context("A draft for order 124")
    say(provider, :assistant, "I've drafted it", 1_100, 1_900)
    say(provider, :user, "No! Don't say the", 2_000, 2_800)
    event(:task_submitted)
    context("was rejected")
    say(provider, :assistant, "Got", 2_850, 2_950)
    say(provider, :user, "'that", 3_000, 3_200)
    assert_receive {:classified, %{new_caller_text: "'that"}}, 1_000

    # Exceeds the real 1,500 ms settle + 600 ms verification deadlines.
    refute_receive {:context, _unnecessary_clarification}, 2_600
    refute_received {:parlora_event, %Event{type: :clarification_requested}}
    assert Parlora.status(session).interpretation == :settled
    assert map_size(Parlora.status(session).jobs) == 2
    assert {:error, :conflict} = Store.confirm(actor, draft.id)
    assert {:ok, ^original} = Store.order("124")
    assert [%{status: "rejected"}] = Store.dashboard(actor).proposals

    # A later delegation for the same refusal associates without repeating the write.
    ScriptedProvider.delegate(provider, "late-refusal")
    event(:delegation_associated)
    assert map_size(Parlora.status(session).jobs) == 2

    say(provider, :assistant, "The draft was rejected", 3_300, 4_000)
    say(provider, :user, "What items are in order 123?", 4_100, 5_000)
    ScriptedProvider.delegate(provider, "items")
    assert event(:task_submitted).payload.request.input.operation == "items"
    context("Travel mug")
    assert map_size(Parlora.status(session).jobs) == 3

    say(provider, :assistant, "A travel mug and coffee beans", 5_100, 6_000)
    say(provider, :user, "Check another order", 6_100, 7_000)
    context("three-digit", 4_000)
    event(:clarification_requested)
    assert map_size(Parlora.status(session).jobs) == 3
  end

  defp say(provider, speaker, delta, start, stop),
    do:
      ScriptedProvider.transcript(provider, %{
        speaker: speaker,
        delta: delta,
        start_ms: start,
        end_ms: stop
      })

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type} = event} -> event
    after
      2_000 -> flunk("Missing #{type}")
    end
  end

  defp context(fragment, timeout \\ 2_000) do
    receive do
      {:context, update} -> assert update.content =~ fragment
    after
      timeout -> flunk("Missing #{fragment}")
    end
  end
end
