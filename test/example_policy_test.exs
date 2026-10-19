Code.require_file("../examples/support/order_policy.ex", __DIR__)
Code.require_file("../examples/support/progress.ex", __DIR__)

defmodule Parlora.ExamplePolicyTest do
  use ExUnit.Case, async: true
  alias Parlora.Channels.Browser
  alias Parlora.{ContextSnapshot, ContextTrigger, Event}
  alias Parlora.Examples.{OrderPolicy, Progress}
  alias Parlora.TestSupport.{BrowserPeer, FakeBackend, MemoryAudio, MemoryChannel, MemoryProvider}

  test "scripted catalog orders accept common spoken numbers and caption punctuation" do
    for phrase <- [
          "order 123",
          "order number: one hundred twenty-three",
          "order a hundred and twenty three",
          "order one-hundred twenty three",
          "order ,1, 2, 3",
          "order number 1 2 3"
        ] do
      snapshot = %ContextSnapshot{
        transcripts: [%{speaker: :user, delta: phrase}],
        pending_delegations: %{"d" => %{status: :pending}}
      }

      assert {:ok, [%{kind: :start_task, input: %{order: "123"}}]} =
               OrderPolicy.interpret(snapshot, %ContextTrigger{kind: :delegation}, [])
    end
  end

  test "incomplete or longer numbers do not start a three-digit lookup" do
    for phrase <- ["order 1", "order 1, 2", "order 1234", "order 1 2 3 4"] do
      snapshot = %ContextSnapshot{
        transcripts: [%{speaker: :user, delta: phrase}],
        pending_delegations: %{"d" => %{status: :pending}}
      }

      assert {:ok, [%{kind: :wait_for_context, recheck_after_ms: 2_000}]} =
               OrderPolicy.interpret(snapshot, %ContextTrigger{kind: :delegation}, [])
    end
  end

  test "reported caption fragments submit the correction and deliver only its result" do
    {_session, provider, backend} = start_example()
    MemoryAudio.inject(provider, :delegation_requested, %{id: "d", offset_ms: 0, target: :client})

    captions(provider, [
      " Can you",
      " check",
      " the",
      " delivery",
      " status",
      " of",
      " the",
      " order ",
      ",1",
      ", 2",
      ", 3"
    ])

    assert_receive {:submitted, first}
    assert first.input == %{order: "123"}

    captions(provider, [
      " Are",
      " you",
      " still",
      " checking",
      " Actually",
      ", I",
      " mean",
      " order",
      " ",
      ",1,",
      " 2",
      ", ",
      "4"
    ])

    assert_receive {:submitted, corrected}
    assert corrected.input == %{order: "124"}
    assert corrected.task_id == first.task_id
    assert corrected.task_revision == 2

    FakeBackend.complete(backend, first, "Old order status")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    refute_receive {:context, _update}, 30
    FakeBackend.complete(backend, corrected, "Order 124 is out for delivery today.")

    assert_receive {:context,
                    %{
                      kind: :speakable,
                      content: "Order 124 is out for delivery today.",
                      task_revision: 2
                    }}

    refute_receive {:submitted, _duplicate}, 30
  end

  for channel <- [MemoryChannel, Browser] do
    @channel channel
    @tag capture_log: true
    test "missing order gets one clarification with #{inspect(channel)}" do
      {session, provider, backend} = start_example([clarification_wait_ms: 30], [], @channel)
      captions(provider, ["Check my order please"])

      MemoryAudio.inject(provider, :delegation_requested, %{
        id: "missing",
        offset_ms: 0,
        target: :client
      })

      assert_receive {:parlora_event, %Event{type: :delegation_pending}}
      assert_receive {:parlora_event, %Event{type: :context_wait_started}}
      assert Parlora.status(session).delegations["missing"].status == :pending
      refute_receive {:submitted, _request}, 10
      assert_receive {:context, clarification}
      assert clarification.content =~ "three-digit"
      assert clarification.delegation_id == "missing"
      assert Progress.status(Parlora.status(session)) =~ "clarification attempted"

      captions(provider, [" sorry "])

      MemoryAudio.inject(provider, :transcript_delta, %{
        speaker: :assistant,
        delta: "What is the number?",
        start_ms: 0,
        end_ms: 100
      })

      refute_receive {:context, _duplicate}, 50
      captions(provider, [" 1", ", 2", ", 4"])
      assert_receive {:submitted, request}
      assert request.input == %{order: "124"}
      FakeBackend.complete(backend, request, "Out for delivery today")
      assert_receive {:context, %{content: "Out for delivery today"}}
    end
  end

  test "late usable captions cancel the clarification timer" do
    {session, provider, _backend} = start_example(clarification_wait_ms: 100)

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "late",
      offset_ms: 0,
      target: :client
    })

    assert_receive {:parlora_event, %Event{type: :context_wait_started}}
    captions(provider, ["Check order 124"])
    assert_receive {:submitted, _request}
    refute_receive {:context, _clarification}, 150
    refute Map.has_key?(Parlora.status(session).delegations["late"], :context_wait)
  end

  test "an unrecognized correction holds the old result until a clarified replacement arrives" do
    {session, provider, backend} = start_example(clarification_wait_ms: 30)
    captions(provider, ["Check order 123"])

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "correction",
      offset_ms: 0,
      target: :client
    })

    assert_receive {:submitted, first}
    captions(provider, [" Actually check order banana"])
    assert_receive {:parlora_event, %Event{type: :context_wait_started}}
    FakeBackend.complete(backend, first, "Old answer must stay held")
    assert_receive {:context, clarification}
    assert clarification.content =~ "three-digit"
    assert Parlora.status(session).interpretation == :unresolved
    refute_receive {:context, %{content: "Old answer must stay held"}}, 50
    captions(provider, [" 124"])
    assert_receive {:submitted, corrected}
    assert corrected.task_revision == 2
    assert corrected.input.order == "124"
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    FakeBackend.complete(backend, corrected, "Current answer")
    assert_receive {:context, %{content: "Current answer"}}
  end

  test "invalid context wait durations are rejected without starting work" do
    for delay <- [0, 60_001] do
      {_session, provider, _backend} = start_example(clarification_wait_ms: delay)

      MemoryAudio.inject(provider, :delegation_requested, %{
        id: "invalid",
        offset_ms: 0,
        target: :client
      })

      assert_receive {:parlora_event,
                      %Event{
                        type: :policy_rejected,
                        payload: %{error: %{code: :invalid_argument}}
                      }}

      refute_receive {:context, _question}, 10
      refute_receive {:submitted, _request}, 10
    end
  end

  test "a rejected clarification stays observable and is not blindly retried" do
    {session, provider, _backend} =
      start_example([clarification_wait_ms: 10], reject_context: true)

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "rejected",
      offset_ms: 0,
      target: :client
    })

    assert_receive {:context, question}
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: id}}
    assert id == question.id
    assert Parlora.status(session).delegations["rejected"].clarification.command_id == id
    captions(provider, [" sorry I don't know "])
    refute_receive {:context, _retry}, 50
    refute_receive {:submitted, _request}, 10
  end

  test "late correction delegations associate with current work without another lookup or result" do
    {session, provider, backend} = start_example()
    captions(provider, ["Check order 123"])

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "original",
      offset_ms: 0,
      target: :client
    })

    assert_receive {:submitted, first}
    captions(provider, [" Actually check order 124"])
    assert_receive {:submitted, corrected}

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "late",
      offset_ms: 100,
      target: :client
    })

    assert_receive {:parlora_event,
                    %Event{type: :delegation_associated, payload: %{id: "late", task_revision: 2}}}

    status = Parlora.status(session)
    assert status.delegations["late"].status == :claimed
    assert status.delegations["late"].task_id == corrected.task_id
    assert Progress.status(status) =~ "revision 2"
    refute_receive {:submitted, _extra}, 30

    FakeBackend.complete(backend, first, "Obsolete")
    assert_receive {:parlora_event, %Event{type: :stale_result}}
    FakeBackend.complete(backend, corrected, "Order 124 result")
    assert_receive {:context, %{content: "Order 124 result", delegation_id: "original"}}

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "late",
      offset_ms: 100,
      target: :client
    })

    refute_receive {:parlora_event, %Event{type: :delegation_associated}}, 30

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "after-result",
      offset_ms: 200,
      target: :client
    })

    assert_receive {:parlora_event,
                    %Event{type: :delegation_associated, payload: %{id: "after-result"}}}

    refute_receive {:submitted, _extra}, 30
    refute_receive {:context, _replayed_result}, 30
  end

  test "a captioned status question preserves the known order and does not hold its result" do
    {session, provider, backend} = start_example(clarification_wait_ms: 30)

    captions(provider, [
      " Yes",
      ", please",
      " check the",
      " order",
      " one",
      " hundred",
      " twenty",
      " three"
    ])

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "status-question",
      offset_ms: 0,
      target: :client
    })

    assert_receive {:submitted, request}
    captions(provider, [" Are you", " checking my", " order"])
    refute_receive {:parlora_event, %Event{type: :context_wait_started}}, 60
    refute_receive {:context, _clarification}, 30
    refute_receive {:submitted, _duplicate}, 10
    FakeBackend.complete(backend, request, "Verified order 123 result")
    assert_receive {:context, %{content: "Verified order 123 result"}}
    assert Parlora.status(session).interpretation == :settled
  end

  test "status follow-ups preserve a recognized request without erasing an unresolved correction" do
    for question <- [
          "Are you checking my order?",
          "Are you still checking the order?",
          "What's the status of my order?",
          "Any update on my order?",
          "What happened with my order?"
        ] do
      task = %{revision: 1, input: %{order: "123"}}

      snapshot = %ContextSnapshot{
        tasks: %{"task" => task},
        transcripts: [%{speaker: :user, delta: "Check order 123. " <> question}]
      }

      assert {:ok, []} =
               OrderPolicy.interpret(snapshot, %ContextTrigger{kind: :transcript_updated}, [])

      snapshot = %{
        snapshot
        | transcripts: [
            %{speaker: :user, delta: "Check order 123. Actually check order banana. " <> question}
          ]
      }

      assert {:ok, [%{kind: :wait_for_context}]} =
               OrderPolicy.interpret(snapshot, %ContextTrigger{kind: :transcript_updated}, [])
    end
  end

  defp start_example(policy_options \\ [], provider_options \\ [], channel \\ MemoryChannel) do
    {:ok, session} =
      Parlora.start_session(
        channel: {channel, observer: self(), signaling: self()},
        provider: {MemoryProvider, Keyword.put(provider_options, :observer, self())},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, policy_options},
        event_sink: self()
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)

    if channel == Browser do
      assert_receive {:parlora_browser, adapter, :attached},
                     %Parlora.Limits{}.startup_timeout_ms

      BrowserPeer.connect(adapter)
    end

    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}

    assert_receive {:parlora_event, %Event{source: :session, type: :ready}},
                   %Parlora.Limits{}.startup_timeout_ms

    {session, provider, backend}
  end

  defp captions(provider, deltas) do
    Enum.each(deltas, fn delta ->
      MemoryAudio.inject(provider, :transcript_delta, %{
        speaker: :user,
        delta: delta,
        start_ms: 0,
        end_ms: 100
      })
    end)
  end

  test "audio diagnostics distinguish native starvation without including arbitrary payload data" do
    event = %Parlora.Event{
      type: :audio_discontinuity,
      source: :channel,
      observed_at_us: -98_000_000,
      payload: %{cause: :device_output_underrun, frames: 128, private_data: "do not log"}
    }

    text = Progress.audio(event, -100_000_000)
    assert text =~ "+2000 ms"
    assert text =~ "channel/device_output_underrun"
    assert text =~ "frames=128"
    refute text =~ "do not log"
    refute text =~ "private_data"

    event = %{
      event
      | payload: %{cause: :playback_starved, epoch: 1, suppressed: false, playback_buffer_ms: 60}
    }

    text = Progress.audio(event, -100_000_000)
    assert text =~ "channel/playback_starved"
    assert text =~ "epoch=1"
    assert text =~ "playback_buffer_ms=60"
    refute text =~ "device_output_underrun"
  end

  test "ordinary audio handoffs do not create console diagnostic lines" do
    assert Progress.audio(%Parlora.Event{type: :playback_observed}, 0) == nil
  end
end
