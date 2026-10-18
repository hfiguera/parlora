defmodule OrderDesk.TaskPilotRegressionTest do
  use ExUnit.Case
  alias OrderDesk.{AppPolicy, ScriptedProvider, Speech}
  alias Parlora.Event

  test "observed A25 caption asks for a number and recovers on explicit spoken 825" do
    # Grouped-825 pilot repetition 2: the source said eight twenty five, but the
    # live caption was A25. Never silently replace a letter with a digit.
    assert Speech.numbers("Check order A25") == []
    assert Speech.numbers("Eight two five") == ["825"]

    classify = fn input ->
      target = if "825" in input.order_candidates, do: "825", else: "unknown"
      {:ok, %{intent: "status", order: target}}
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           [classify: classify, clarification_settle_ms: 30, clarification_verify_ms: 20]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    ScriptedProvider.say(provider, "Check order A25")
    ScriptedProvider.delegate(provider, "ambiguous-caption")
    event(:clarification_requested)
    assert Parlora.status(session).jobs == %{}
    assert Parlora.snapshot(session).tasks == %{}

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "What is the three digit order number?"
    })

    ScriptedProvider.say(provider, "Eight two five")
    request = event(:task_submitted).payload.request
    assert request.input.order == "825"
    assert request.input.operation == "status"
    event(:request_completed, :backend)
    assert map_size(Parlora.status(session).jobs) == 1
  end

  test "caption punctuation inside a paused ID cannot silently select a prefix order" do
    classify = fn input ->
      assert "124" in input.order_candidates
      {:ok, %{intent: "status", order: "124"}}
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           [classify: classify, clarification_settle_ms: 30, clarification_verify_ms: 20]}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    ScriptedProvider.say(provider, "Check order one hundred twenty. Four")
    ScriptedProvider.delegate(provider, "punctuated-caption")
    event(:clarification_requested)
    assert Parlora.status(session).jobs == %{}

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Please repeat the full number."
    })

    ScriptedProvider.say(provider, "Check order one two four")
    request = event(:task_submitted).payload.request
    assert request.input.order == "124"
    event(:request_completed, :backend)
    assert map_size(Parlora.status(session).jobs) == 1
  end

  test "observed trailing-order confidence split releases the items result without duplicate work" do
    owner = self()
    Application.put_env(:order_desk, :lookup_delays, %{"124" => 150})
    on_exit(fn -> Application.delete_env(:order_desk, :lookup_delays) end)

    classify = fn state ->
      if state.new_caller_text == " order" do
        send(owner, :replayed_split)

        OrderDesk.Interpretation.interpret_answers(
          %{
            "intent" => %{
              choice: "handled_continuation",
              probabilities: %{
                "handled_continuation" => 0.61,
                "items" => 0.39
              }
            },
            "target" => %{choice: "124", probabilities: %{"124" => 1.0}}
          },
          state
        )
      else
        intent = if state.new_caller_text =~ "What items", do: "items", else: "status"
        {:ok, %{intent: intent, order: "124"}}
      end
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           classify: classify, clarification_settle_ms: 30, clarification_verify_ms: 20}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    ScriptedProvider.say(provider, "Check order 124")
    ScriptedProvider.delegate(provider, "status")
    event(:task_submitted)
    assert_receive {:context, status}, 2_000
    assert status.content =~ "out for delivery"

    ScriptedProvider.transcript(provider, %{speaker: :assistant, delta: "It is out for delivery."})

    ScriptedProvider.say(provider, "What items are in that")
    items = event(:task_submitted).payload.request
    assert items.input.operation == "items"
    assert items.delegation_id == nil
    ScriptedProvider.say(provider, " order")
    ScriptedProvider.delegate(provider, "items-late")
    assert_receive :replayed_split, 1_000
    assert_receive {:context, result}, 2_000
    assert result.content =~ "Desk lamp"
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 250
    progress = Parlora.status(session)
    assert progress.interpretation == :settled
    assert map_size(progress.jobs) == 2
    assert Enum.all?(progress.jobs, fn {_, job} -> job.delivery == :accepted end)
    assert Enum.all?(progress.delegations, fn {_, d} -> d.status == :claimed end)
  end

  test "completed items suffix does not clarify, suppress a new read, or swallow a correction" do
    owner = self()

    classify = fn state ->
      if state.new_caller_text == " there" do
        assert state.active_task == %{operation: "items", order: "825", status: :completed}
        assert state.handled_caller_input == "Do you know what items are"
        send(owner, :replayed_completed_suffix)

        OrderDesk.Interpretation.interpret_answers(
          %{
            "speech_act" => %{
              choice: "presence",
              probabilities: %{"presence" => 0.55, "other" => 0.2, "uncertain" => 0.25}
            },
            "intent" => %{
              choice: "handled_continuation",
              probabilities: %{"handled_continuation" => 0.99}
            },
            "target" => %{choice: "825", probabilities: %{"825" => 0.79, "unknown" => 0.21}}
          },
          state
        )
      else
        intent =
          cond do
            state.new_caller_text =~ "saved instructions" -> "instructions"
            state.new_caller_text =~ "items" -> "items"
            true -> "order_status"
          end

        OrderDesk.Interpretation.interpret_answers(
          %{
            "intent" => %{choice: intent, probabilities: %{intent => 0.99}},
            "target" => %{choice: "825", probabilities: %{"825" => 0.99}}
          },
          state
        )
      end
    end

    {:ok, session} =
      OrderDesk.start_session(
        {Parlora.Channels.LocalAudio, device: :synthetic},
        {ScriptedProvider, observer: self(), audio: false},
        context_policy:
          {AppPolicy,
           classify: classify, clarification_settle_ms: 30, clarification_verify_ms: 20}
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session, :cancel) end)
    assert_receive {:scripted_provider, provider}
    event(:ready)
    ScriptedProvider.say(provider, "Check order 825")
    ScriptedProvider.delegate(provider, "status-825")
    event(:task_submitted)
    assert_receive {:context, _status}, 2_000
    ScriptedProvider.transcript(provider, %{speaker: :assistant, delta: "It is processing."})

    ScriptedProvider.say(provider, "Do you know what items are")
    items = event(:task_submitted).payload.request
    assert items.input.operation == "items"
    assert items.input.order == "825"
    assert_receive {:context, result}, 2_000
    assert result.content =~ "Order 825 contains 3 Notebook"

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Order eight twenty five has three notebooks."
    })

    ScriptedProvider.say(provider, " there")
    ScriptedProvider.delegate(provider, "items-late")
    assert_receive :replayed_completed_suffix, 1_000
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 250
    refute_receive {:parlora_event, %Event{type: :task_submitted}}, 100
    assert map_size(Parlora.status(session).jobs) == 2

    ScriptedProvider.transcript(provider, %{speaker: :assistant, delta: "Those are the items."})
    ScriptedProvider.say(provider, "What are the saved instructions?")
    instructions = event(:task_submitted).payload.request
    assert instructions.input.operation == "instructions"
    assert instructions.input.order == "825"
    assert_receive {:context, saved}, 2_000
    assert saved.content =~ "Saved delivery instructions for order 825"

    ScriptedProvider.transcript(provider, %{
      speaker: :assistant,
      delta: "Those are the instructions."
    })

    ScriptedProvider.say(provider, "Sorry, I mean order 124")
    ScriptedProvider.delegate(provider, "corrected-instructions")
    corrected = event(:task_submitted).payload.request
    assert corrected.input.operation == "instructions"
    assert corrected.input.order == "124"
    assert_receive {:context, corrected_saved}, 2_000
    assert corrected_saved.content =~ "Saved delivery instructions for order 124"
    refute_receive {:parlora_event, %Event{type: :clarification_requested}}, 250
    progress = Parlora.status(session)
    assert progress.interpretation == :settled
    assert map_size(progress.jobs) == 4
    assert Enum.all?(progress.jobs, fn {_, job} -> job.delivery == :accepted end)
    assert Enum.all?(progress.delegations, fn {_, d} -> d.status == :claimed end)
  end

  defp event(type, source \\ :session) do
    receive do
      {:parlora_event, %Event{source: ^source, type: ^type} = event} -> event
    after
      2_000 -> flunk("Missing session event #{type}")
    end
  end
end
