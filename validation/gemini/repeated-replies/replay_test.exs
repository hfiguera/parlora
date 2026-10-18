# Diagnosis, not acceptance tests: these assertions reproduce the current defects.
# Run with MIX_ENV=test mix run from a standalone OrderDesk consumer.
root = Path.expand("../../..", __DIR__)

for file <- ["memory_audio", "memory_channel", "fake_backend"] do
  Code.require_file("test/support/#{file}.ex", root)
end

ExUnit.start()

defmodule RepeatedRepliesProvider do
  use Parlora.TestSupport.MemoryAudio, role: :provider

  @impl true
  def resolve_delegation(pid, id, outcome) do
    send(:sys.get_state(pid).options[:observer], {:resolution, id, outcome})
    :ok
  end
end

defmodule RepeatedRepliesSession do
  use GenServer
  def init(owner), do: {:ok, owner}

  def handle_call({:append_context, update}, _from, owner) do
    send(owner, {:announcement, update})
    {:reply, :ok, owner}
  end
end

defmodule RepeatedRepliesReplayTest do
  use ExUnit.Case, async: false
  alias Parlora.{Event, ContextUpdate}
  alias Parlora.TestSupport.{MemoryAudio, MemoryChannel, FakeBackend}
  alias Parlora.Providers.Gemini.{Calls, Protocol}
  alias OrderDesk.SaveAnnouncements

  defp boot do
    classifier = fn input ->
      cond do
        String.contains?(input.latest_caller_segment, "instructions") ->
          {:ok, %{intent: "instructions", order: "124"}}

        String.contains?(input.latest_caller_segment, "124") ->
          {:ok, %{intent: "status", order: "124"}}

        true ->
          {:ok, %{intent: "status", order: "123"}}
      end
    end

    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {RepeatedRepliesProvider, observer: self()},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderDesk.AppPolicy, classify: classifier},
        event_sink: self()
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:adapter, :provider, provider}, 1_000
    assert_receive {:adapter, :backend, backend}, 1_000
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, 1_000
    {session, provider, backend}
  end

  defp speech(provider, text, speaker \\ :user),
    do:
      MemoryAudio.inject(provider, :transcript_delta, %{
        speaker: speaker,
        delta: text,
        start_ms: nil,
        end_ms: nil,
        timing: :unavailable
      })

  defp delegate(provider, id),
    do:
      MemoryAudio.inject(provider, :delegation_requested, %{
        id: id,
        target: :client,
        offset_ms: nil
      })

  defp call(id),
    do: %{"id" => id, "name" => Protocol.function(), "args" => %{"request" => "Check order"}}

  defp completed_correction do
    {session, provider, backend} = boot()
    speech(provider, "Sure, let's check the order 123.")
    delegate(provider, "first")
    assert_receive {:submitted, first}, 1_000
    FakeBackend.complete(backend, first, "Order 123 is shipped")
    assert_receive {:context, first_update}, 1_000
    speech(provider, "Order 123 is shipped", :assistant)
    speech(provider, "Sorry, let me make a mistake. The order number is 124.")
    assert_receive {:submitted, second}, 1_000
    assert second.input.order == "124"
    FakeBackend.complete(backend, second, "Order 124 is out for delivery.")
    assert_receive {:context, second_update}, 1_000
    {session, provider, backend, first_update, second_update}
  end

  test "a completed correction is delivered as content, then again through association" do
    {session, provider, _backend, first, correction} = completed_correction()
    assert first.delegation_id == "first"
    # The replacement retains the original task's already-completed call ID.
    assert correction.delegation_id == "first"
    delegate(provider, "correction")
    assert_receive {:resolution, "correction", %{result: summary}}, 1_000
    assert summary == correction.content
    assert map_size(Parlora.status(session).jobs) == 2
    refute_receive {:submitted, _duplicate}, 30

    {:new, calls} = Calls.admit(Calls.new(20), call("first"))
    {:ok, _, calls} = Calls.context(calls, "first", first.content)
    {:new, calls} = Calls.admit(calls, call("correction"))

    {:ok, first_message, calls} =
      Calls.context(calls, correction.delegation_id, correction.content)

    {:ok, second_message, _} = Calls.complete(calls, "correction", %{result: summary})
    assert first_message.clientContent.turnComplete
    assert hd(hd(first_message.clientContent.turns).parts).text =~ summary
    assert hd(second_message.toolResponse.functionResponses).response.result == summary
    assert hd(second_message.toolResponse.functionResponses).scheduling == "WHEN_IDLE"
  end

  test "a transcript-driven followup still emits speakable content after an early model answer" do
    {_session, provider, backend, _first, _correction} = completed_correction()
    speech(provider, "Order 124 is out for delivery.", :assistant)
    speech(provider, "And what are the delivery instructions?")
    assert_receive {:submitted, request}, 1_000
    assert request.input.operation == "instructions"
    assert request.delegation_id == nil
    speech(provider, "The delivery instructions are to leave it with your neighbor.", :assistant)

    FakeBackend.complete(
      backend,
      request,
      "Saved delivery instructions for order 124: Leave with My Neighbor. Record version 2. This is a database read; no changes were made."
    )

    assert_receive {:context, update}, 1_000
    assert update.kind == :speakable
    assert update.delegation_id == nil
    {:ok, message, _} = Calls.context(Calls.new(20), nil, update.content)
    assert message.clientContent.turnComplete
  end

  defp announcement_state(session, attempts) do
    now = System.monotonic_time(:millisecond)

    %{
      session: session,
      pending: [
        %{
          result: %{order: "124", instructions: "left in my front door", version: 3},
          attempts: attempts,
          command: "previous",
          sent_at: now - 7_000,
          due: now + 20_000
        }
      ],
      versions: %{"124" => 3},
      evidence: %{},
      text: "",
      last_speech: now - 2_000,
      provider_activity: :idle,
      idle_ms: 1_000,
      retry_ms: 6_000,
      tick_ms: 100_000
    }
  end

  test "the actual paraphrased save caption leaves the announcement pending and permits a retry" do
    {:ok, session} = GenServer.start_link(RepeatedRepliesSession, self())
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    state = announcement_state(session, 1)

    {:noreply, state} =
      SaveAnnouncements.handle_info(
        {:parlora_event,
         %Event{
           source: :provider,
           type: :transcript_delta,
           payload: %{
             speaker: :assistant,
             delta:
               "For order 124, the delivery instructions to leave it at your front door are now saved."
           }
         }},
        state
      )

    assert length(state.pending) == 1
    assert state.evidence == %{}
    # Advance only the pause clock; the save itself is never retried.
    state = %{state | last_speech: System.monotonic_time(:millisecond) - 2_000}
    {:noreply, next} = SaveAnnouncements.handle_info(:tick, state)
    assert hd(next.pending).attempts == 2
    assert_receive {:announcement, %ContextUpdate{kind: :instruction}}
  end

  test "caption silence permits an announcement before a standard Gemini speech turn finishes" do
    {:ok, session} = GenServer.start_link(RepeatedRepliesSession, self())
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    # Actual wire shape: after the previous idle, audio/captions arrive without
    # interactionStatus. Neither emits a public activity update in Protocol.
    events =
      Protocol.events(%{
        "serverContent" => %{
          "outputTranscription" => %{"text" => "Review the draft and press Confirm."},
          "modelTurn" => %{
            "parts" => [
              %{"inlineData" => %{"mimeType" => "audio/pcm;rate=24000", "data" => "AAA="}}
            ]
          },
          "generationComplete" => true
        }
      })

    refute Enum.any?(events, &match?({:activity, _}, &1))
    assert :generation_complete in events
    refute :utterance_complete in events
    state = announcement_state(session, 0)
    # No turnComplete or playback completion has arrived, but this still submits.
    {:noreply, next} = SaveAnnouncements.handle_info(:tick, state)
    assert hd(next.pending).attempts == 1
    assert_receive {:announcement, %ContextUpdate{kind: :speakable}}
  end
end
