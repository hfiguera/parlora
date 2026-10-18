defmodule OrderDesk.SaveAnnouncementsTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias OrderDesk.SaveAnnouncements
  alias Parlora.Event

  defmodule Session do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    def init(owner),
      do: {:ok, %{owner: owner, context: %{actor: "test", voice_provider: :gemini}}}

    def handle_call({:subscribe, subscriber}, _from, state) do
      send(state.owner, {:subscriber, subscriber})
      {:reply, :ok, state}
    end

    def handle_call({:append_context, context}, _from, state) do
      send(state.owner, {:context, context})
      {:reply, :ok, state}
    end

    def handle_call(:snapshot, _from, state),
      do: {:reply, %Parlora.ContextSnapshot{application_context: state.context}, state}

    def handle_call({:context, context}, _from, state) do
      send(state.owner, {:application_context, context})
      {:reply, :ok, %{state | context: context}}
    end
  end

  defp start(options \\ []) do
    session = start_supervised!({Session, self()})

    worker =
      start_supervised!(
        {SaveAnnouncements,
         Keyword.merge(
           [session: session, idle_ms: 60, retry_ms: 120, deadline_ms: 600, tick_ms: 10],
           options
         )}
      )

    assert_receive {:subscriber, ^worker}, 1_000
    {session, worker}
  end

  defp result(version \\ 4),
    do: %{order: "124", instructions: "Leave it with my neighbor", version: version}

  defp speech(worker, text, speaker \\ :assistant),
    do:
      send(
        worker,
        {:parlora_event,
         %Event{
           source: :provider,
           type: :transcript_delta,
           payload: %{speaker: speaker, delta: text}
         }}
      )

  test "Gemini save uses one submission, holds clarification, and observes a late confirmation" do
    {session, worker} = start(provider: Parlora.Providers.Gemini, deadline_ms: 400)
    SaveAnnouncements.saved(worker, result())
    assert_receive {:application_context, %{save_announcement_until_ms: deadline, actor: "test"}}
    assert deadline > System.monotonic_time(:millisecond)
    assert_receive {:context, %{kind: :speakable, id: id}}, 500
    send(worker, {:parlora_event, %Event{type: :context_submitted, command_id: id}})
    speech(worker, "Hello, are you there?", :user)
    # Cross the old retry interval, then the coordination deadline.
    refute_receive {:context, _retry}, 450
    assert_receive {:application_context, %{save_announcement_until_ms: nil}}
    assert SaveAnnouncements.status(worker).pending == 0
    assert SaveAnnouncements.status(worker).evidence["124"].stage == :unconfirmed
    assert Parlora.snapshot(session).application_context.actor == "test"

    speech(worker, "Saved order 124: Leave it with my neighbor.")
    assert SaveAnnouncements.status(worker).evidence["124"].stage == :transcript_observed
    SaveAnnouncements.saved(worker, result())
    refute_receive {:context, _retry_or_duplicate}, 150
  end

  test "a newer Gemini save cannot be retired by a late confirmation of its previous destination" do
    {_session, worker} = start(provider: Parlora.Providers.Gemini, deadline_ms: 600)
    SaveAnnouncements.saved(worker, result())
    assert_receive {:context, _}, 500
    SaveAnnouncements.saved(worker, %{result(5) | instructions: "Leave it at reception"})
    assert_receive {:context, %{content: text}}, 500
    assert text =~ "version 5"
    speech(worker, "Saved order 124: Leave it with my neighbor.")
    assert SaveAnnouncements.status(worker).pending == 1
    speech(worker, "reset", :user)
    speech(worker, "Saved order 124: Leave it at reception.")
    assert SaveAnnouncements.status(worker).pending == 0
    assert SaveAnnouncements.status(worker).evidence["124"].stage == :transcript_observed
  end

  test "save while speaking waits for a pause without requiring a caller prompt" do
    {_session, worker} = start(tick_ms: 60_000, deadline_ms: 120_000)
    SaveAnnouncements.saved(worker, result())
    assert SaveAnnouncements.status(worker).pending == 1

    for text <- ["A draft is on the page.", " Review the exact order.", " Then press Confirm."] do
      speech(worker, text)
      assert SaveAnnouncements.status(worker).pending == 1
      # Drive the pause boundary explicitly. A loaded scheduler must not turn
      # the test's 35 ms receive wait into an unintended 60 ms speech pause.
      :sys.replace_state(worker, fn state ->
        %{state | last_speech: System.monotonic_time(:millisecond) + 60_000}
      end)

      send(worker, :tick)
      assert SaveAnnouncements.status(worker).pending == 1
      refute_received {:context, _update}
    end

    :sys.replace_state(worker, fn state ->
      %{state | last_speech: System.monotonic_time(:millisecond) - state.idle_ms}
    end)

    send(worker, :tick)
    assert SaveAnnouncements.status(worker).pending == 1
    assert_received {:context, %{kind: :speakable, content: content}}
    assert content =~ "saved delivery instructions for order 124"
    assert content =~ "earlier request to press Confirm is obsolete"
    assert content =~ "Do not wait"
  end

  test "background activity defers a saved announcement and unconfirmed submission is not speech evidence" do
    {_session, worker} = start(deadline_ms: 1_000)

    send(
      worker,
      {:parlora_event,
       %Event{source: :provider, type: :provider_activity, payload: %{state: :in_progress}}}
    )

    SaveAnnouncements.saved(worker, result())
    refute_receive {:context, _}, 150

    send(
      worker,
      {:parlora_event,
       %Event{source: :provider, type: :provider_activity, payload: %{state: :idle}}}
    )

    assert_receive {:context, %{id: id}}
    send(worker, {:parlora_event, %Event{type: :context_submitted, command_id: id}})

    assert %{pending: 1, evidence: %{"124" => %{stage: :submission_unconfirmed}}} =
             SaveAnnouncements.status(worker)
  end

  test "acknowledgment alone does not retire a pending announcement; retry and deadline are bounded" do
    {_session, worker} = start()
    SaveAnnouncements.saved(worker, result())
    assert_receive {:context, %{kind: :speakable, id: first}}, 1_000
    send(worker, {:parlora_event, %Event{type: :context_acknowledged, command_id: first}})

    assert %{pending: 1, evidence: %{"124" => %{stage: :provider_acknowledged}}} =
             SaveAnnouncements.status(worker)

    assert_receive {:context, %{kind: :instruction, id: second}}, 1_000
    refute first == second
    refute_receive {:context, _third}, 650

    assert %{pending: 0, evidence: %{"124" => %{stage: :unconfirmed}}} =
             SaveAnnouncements.status(worker)
  end

  test "fragmented saved confirmation suppresses retry and records transcript evidence only" do
    {_session, worker} = start()
    SaveAnnouncements.saved(worker, result())
    assert_receive {:context, _update}, 1_000
    speech(worker, "Saved delivery instructions for order one twenty-four: ")
    speech(worker, "Leave it with my ")
    speech(worker, "neighbor.")

    assert %{pending: 0, evidence: %{"124" => %{stage: :transcript_observed}}} =
             SaveAnnouncements.status(worker)

    SaveAnnouncements.saved(worker, result())
    refute_receive {:context, _duplicate}, 250
  end

  for {stored, spoken} <- [{"neighbor", "neighbour"}, {"neighbour", "neighbor"}] do
    @stored stored
    @spoken spoken
    test "#{stored} saved text recognizes fragmented #{spoken} confirmation without retry" do
      {_session, worker} = start()
      saved = %{result() | order: "123", instructions: "leave with my " <> @stored}
      SaveAnnouncements.saved(worker, saved)
      assert_receive {:context, %{content: content}}, 1_000
      assert content =~ saved.instructions
      speech(worker, "Oh, I see it was saved for order one twenty-three: leave with my ")
      {head, tail} = String.split_at(@spoken, 5)
      speech(worker, head)
      assert SaveAnnouncements.status(worker).pending == 1
      speech(worker, tail <> ".")

      assert %{pending: 0, evidence: %{"123" => %{stage: :transcript_observed}}} =
               SaveAnnouncements.status(worker)

      SaveAnnouncements.saved(worker, saved)
      refute_receive {:context, _duplicate_or_retry}, 250
    end
  end

  test "spelling normalization retains order, negation, speaker and destination guards" do
    for {speaker, text} <- [
          {:assistant, "Saved order 123: Leave it with my neighbour."},
          {:assistant, "Not saved order 124: Leave it with my neighbour."},
          {:user, "Saved order 124: Leave it with my neighbour."},
          {:assistant, "Saved order 124: Leave it behind my neighbour."},
          {:assistant, "Saved order 124: Leave it with my neighbourhood."}
        ] do
      state = %{
        pending: [%{attempts: 1, result: result()}],
        text: "",
        last_speech: 0,
        evidence: %{}
      }

      {:noreply, state} =
        SaveAnnouncements.handle_info(
          {:parlora_event,
           %Event{
             source: :provider,
             type: :transcript_delta,
             payload: %{speaker: speaker, delta: text}
           }},
          state
        )

      assert length(state.pending) == 1
      assert state.evidence == %{}
    end
  end

  test "unrelated, negated and caller speech is not confirmation evidence" do
    {_session, worker} = start()
    SaveAnnouncements.saved(worker, result())
    assert_receive {:context, _update}, 1_000
    speech(worker, "Saved order 123: Leave it with my neighbor.")
    assert SaveAnnouncements.status(worker).pending == 1
    speech(worker, "Saved order 124: Leave it with my neighbor.", :user)
    assert SaveAnnouncements.status(worker).pending == 1
    speech(worker, "Not saved order 124: Leave it with my neighbor.")
    assert SaveAnnouncements.status(worker).pending == 1
  end

  test "the human-call front-door paraphrase retires the save without a retry" do
    {_session, worker} = start()
    SaveAnnouncements.saved(worker, %{result() | instructions: "left in my front door"})
    assert_receive {:context, _}, 1_000

    speech(
      worker,
      "For order 124, the delivery instructions to leave it at your front door are now saved."
    )

    assert SaveAnnouncements.status(worker).pending == 0
    assert SaveAnnouncements.status(worker).evidence["124"].stage == :transcript_observed
    refute_receive {:context, _retry}, 250
  end

  test "destination variants never erase different locations, negation or arbitrary prepositions" do
    {_session, worker} = start(idle_ms: 1_000, deadline_ms: 2_000)
    SaveAnnouncements.saved(worker, %{result() | instructions: "left in my front door"})
    # Simulate one submitted attempt without waiting on the wall clock.
    :sys.replace_state(worker, fn state ->
      %{
        state
        | pending:
            Enum.map(
              state.pending,
              &%{&1 | attempts: 1, sent_at: System.monotonic_time(:millisecond)}
            )
      }
    end)

    for text <- [
          "Saved order 123: leave it at your front door.",
          "Not saved order 124: leave it at your front door.",
          "Saved order 124: leave it at your back door.",
          "Saved order 124: leave it behind your front door.",
          "Saved order 124: leave it at your front doorway."
        ] do
      speech(worker, "reset", :user)
      speech(worker, text)
      assert SaveAnnouncements.status(worker).pending == 1
    end

    :sys.replace_state(worker, fn state ->
      %{
        state
        | pending:
            Enum.map(state.pending, fn item ->
              %{item | result: %{item.result | instructions: "leave it in my garage"}}
            end)
      }
    end)

    speech(worker, "reset", :user)
    speech(worker, "Saved order 124: leave it at your garage.")
    assert SaveAnnouncements.status(worker).pending == 1
    speech(worker, "reset", :user)
    speech(worker, "Saved order 124: leave it in your garage.")
    assert SaveAnnouncements.status(worker).pending == 0
  end

  test "caption silence and idle background status cannot interrupt an unfinished utterance" do
    {_session, worker} = start(idle_ms: 2_000, deadline_ms: 10_000, tick_ms: 60_000)

    send(
      worker,
      {:parlora_event,
       %Event{source: :provider, type: :provider_speech, payload: %{state: :speaking}}}
    )

    SaveAnnouncements.saved(worker, result())
    speech(worker, "Review this draft and press Confirm.")
    send(worker, :tick)
    SaveAnnouncements.status(worker)
    refute_receive {:context, _}, 0

    send(
      worker,
      {:parlora_event,
       %Event{source: :provider, type: :provider_speech, payload: %{state: :idle}}}
    )

    # Advance caption time explicitly; source playback must still hold the pause.
    :sys.replace_state(worker, fn state ->
      %{state | last_speech: System.monotonic_time(:millisecond) - state.idle_ms}
    end)

    # Speech ended, but real source audio is still reaching the channel.
    for _ <- 1..4 do
      send(
        worker,
        {:parlora_event,
         %Event{
           source: :channel,
           type: :playback_observed,
           payload: %{stage: :handed_off, source_audio?: true}
         }}
      )

      send(worker, :tick)
      SaveAnnouncements.status(worker)
      refute_receive {:context, _}, 0
    end

    :sys.replace_state(worker, fn state ->
      %{state | last_playback: System.monotonic_time(:millisecond) - state.idle_ms}
    end)

    # Browser silence packets must not keep an announcement pending forever.
    for _ <- 1..4 do
      send(
        worker,
        {:parlora_event,
         %Event{
           source: :channel,
           type: :playback_observed,
           payload: %{stage: :handed_off, source_audio?: false}
         }}
      )
    end

    send(worker, :tick)
    assert_receive {:context, _}, 1_000
  end

  test "continuous source silence without a speech-state contract preserves OpenAI announcement behavior" do
    {_session, worker} = start()
    SaveAnnouncements.saved(worker, result())
    speech(worker, "Review the draft on the page.")
    refute_receive {:context, _}, 35

    for _ <- 1..6 do
      send(
        worker,
        {:parlora_event,
         %Event{source: :channel, type: :playback_observed, payload: %{stage: :queued}}}
      )

      Process.sleep(15)
    end

    assert_receive {:context, _}, 200
  end

  test "newer queued save replaces the older version; duplicate and older events do not resubmit" do
    {_session, worker} = start()
    SaveAnnouncements.saved(worker, result())
    SaveAnnouncements.saved(worker, %{result(5) | instructions: "Leave it at reception"})
    SaveAnnouncements.saved(worker, result())
    assert_receive {:context, %{content: content}}, 1_000
    assert content =~ "version 5"
    assert content =~ "Leave it at reception"
    refute content =~ "neighbor"
    assert SaveAnnouncements.status(worker).pending == 1
  end

  test "continuous speech expires the notification without interrupting or unbounded buffering" do
    {_session, worker} = start(idle_ms: 1_000, deadline_ms: 100)

    for order <- 101..112 do
      SaveAnnouncements.saved(worker, %{result() | order: to_string(order)})
    end

    assert %{pending: 8, evidence: evidence} = SaveAnnouncements.status(worker)
    assert map_size(evidence) == 8
    refute_receive {:context, _update}, 180
    assert SaveAnnouncements.status(worker).pending == 0
  end

  test "rejection remains unconfirmed and session death releases the worker" do
    {session, worker} = start()
    SaveAnnouncements.saved(worker, result())
    assert_receive {:context, %{id: id}}, 1_000
    send(worker, {:parlora_event, %Event{type: :context_rejected, command_id: id}})
    assert SaveAnnouncements.status(worker).evidence["124"].stage == :provider_rejected
    ref = Process.monitor(worker)
    GenServer.stop(session)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
    refute_receive {:context, _retry}, 180
  end
end
