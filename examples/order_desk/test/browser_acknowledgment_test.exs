defmodule OrderDesk.BrowserAcknowledgmentTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, Interpretation, ScriptedProvider, Store}
  alias Parlora.Event

  for saved? <- [false, true] do
    @saved saved?
    test "browser acknowledgment settles with saved=#{saved?} and never changes the order" do
      actor = Parlora.ID.new()
      owner = self()

      classify = fn state ->
        cond do
          state.new_caller_text =~ "Was it saved" ->
            {:ok, %{intent: "instructions", order: "124"}}

          state.new_caller_text =~ "I think I did" ->
            send(owner, {:ack_state, state})
            # Recorded shape of the live replay response; target confidence is
            # irrelevant to an acknowledgment, while intent still needs 80%.
            Interpretation.interpret_answers(%{
              "intent" => %{choice: "none", probabilities: %{"none" => 0.99}},
              "target" => %{choice: "124", probabilities: %{"124" => 0.51}}
            })

          true ->
            {:ok, %{intent: "delivery", order: "124"}}
        end
      end

      {session, provider} = start(actor, classify)
      ScriptedProvider.say(provider, "For order 124 leave it at reception")
      ScriptedProvider.delegate(provider, "draft")
      request = event(:task_submitted).payload.request
      context("A draft for order 124")
      if @saved, do: assert({:ok, _} = Store.confirm(actor, request.id))
      before_dashboard = Store.dashboard(actor)
      {:ok, before_order} = Store.order("124")

      ScriptedProvider.transcript(provider, %{
        speaker: :assistant,
        delta: "Review and confirm the draft on the page."
      })

      ScriptedProvider.say(provider, "I think I did")
      assert_receive {:ack_state, state}, 1_000
      expected = if @saved, do: "applied", else: "pending"
      assert [%{status: ^expected, order: "124"}] = state.delivery_drafts
      refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 400
      refute_received {:parlora_event, %Event{type: :task_submitted}}
      assert Parlora.status(session).interpretation == :settled
      assert Store.dashboard(actor) == before_dashboard
      assert Store.order("124") == {:ok, before_order}

      # A delayed delegation associates, without duplicating the draft.
      ScriptedProvider.delegate(provider, "ack")
      event(:delegation_associated)
      assert map_size(Parlora.status(session).jobs) == 1

      # A real question still dispatches a read of the saved instructions.
      ScriptedProvider.say(provider, " Was it saved on the page?")
      ScriptedProvider.delegate(provider, "verify")
      assert event(:task_submitted).payload.request.input.operation == "instructions"
      context(before_order.instructions)
      assert Store.dashboard(actor) == before_dashboard
      assert Store.order("124") == {:ok, before_order}
    end
  end

  test "low-confidence none still requires clarification and never claims a save failed" do
    judgment =
      Interpretation.interpret_answers(%{
        "intent" => %{choice: "none", probabilities: %{"none" => 0.67}},
        "target" => %{choice: "124", probabilities: %{"124" => 0.59}}
      })

    assert {:error, {:uncertain, %{uncertain_fields: ["intent"]}}} = judgment

    snapshot = %Parlora.ContextSnapshot{
      session_id: "uncertain-ack",
      tasks: %{
        "draft" => %{
          revision: 1,
          status: :completed,
          input: %{order: "124", operation: "delivery", user_revision: 1},
          context_wait: %{expired?: true, recheck_key: "3:verify"}
        }
      },
      transcripts: [%{speaker: :user, delta: "What about that?", arrival_order: 3}]
    }

    for result <- [judgment, {:error, :timeout}, {:error, :uncertain}] do
      assert {:ok, [%{kind: :request_clarification, message: message}]} =
               AppPolicy.interpret(snapshot, %Parlora.ContextTrigger{},
                 classify: fn _ -> result end
               )

      refute message =~ "No order changes were made"
    end
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
           delivery_settle_ms: 40,
           clarification_settle_ms: 120,
           clarification_verify_ms: 60}
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
      2_000 -> flunk("Missing context #{fragment}")
    end
  end
end
