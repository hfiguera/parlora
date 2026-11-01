defmodule Parlora.SessionRetentionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parlora.{ContextDecision, ContextSnapshot, Event, Limits}
  alias Parlora.Session.{Retention, State}

  alias Parlora.TestSupport.{
    ControlledPolicy,
    FakeBackend,
    MemoryAudio,
    MemoryChannel,
    MemoryProvider
  }

  defmodule PassivePolicy do
    def interpret(_snapshot, _trigger, _options), do: {:ok, []}
  end

  property "rolling history is a contiguous recent suffix bounded in both entries and encoded bytes" do
    check all(
            deltas <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 100),
                min_length: 30,
                max_length: 150
              ),
            max_entries <- integer(1..12),
            max_bytes <- integer(256..2_048)
          ) do
      state = state(max_entries, max_bytes)

      final =
        Enum.reduce(deltas, state, fn delta, state ->
          {:ok, state} = Retention.append_transcript(state, caption(delta))
          history = state.context.transcript_retention
          entries = state.context.transcripts
          assert length(entries) == history.retained
          assert history.retained <= max_entries

          assert history.retained_bytes ==
                   Enum.reduce(entries, 0, fn entry, bytes ->
                     bytes + :erlang.external_size(entry)
                   end)

          assert history.retained_bytes <= max_bytes
          assert hd(entries).delta == delta

          assert Enum.map(entries, & &1.arrival_order) ==
                   Enum.to_list(
                     (state.context.revision - 1)..(state.context.revision - history.retained)//-1
                   )

          state
        end)

      history = final.context.transcript_retention
      assert history.retained + history.dropped == length(deltas)

      assert Enum.map(final.context.transcripts, & &1.delta) ==
               deltas |> Enum.reverse() |> Enum.take(history.retained)
    end
  end

  test "close mode rejects overflow without altering retained history" do
    initial = state(2, 1_024, :close)
    {:ok, first} = Retention.append_transcript(initial, caption("one"))
    {:ok, full} = Retention.append_transcript(first, caption("two"))
    assert {:error, %{code: :backpressure}} = Retention.append_transcript(full, caption("three"))
    assert full.context.transcript_retention.retained == 2
    assert full.context.transcript_retention.dropped == 0
  end

  test "a single oversized entry is rejected before dropping useful history" do
    {:ok, state} = Retention.append_transcript(state(4, 256), caption("kept"))

    assert {:error, %{code: :backpressure, details: %{resource: :entry_bytes}}} =
             Retention.append_transcript(state, caption(String.duplicate("x", 512)))

    assert [%{delta: "kept"}] = state.context.transcripts
  end

  test "compaction preserves application state and task identity while retiring a stale policy snapshot" do
    {session, provider, backend} = boot(4, {ControlledPolicy, observer: self()})
    inject(provider, :delegation_requested, %{id: "work", offset_ms: 0})
    assert_receive {:policy, initial, _snapshot, _trigger}

    send(
      initial,
      {:decisions,
       [%ContextDecision{kind: :start_task, delegation_id: "work", input: %{order: "123"}}]}
    )

    assert_receive {:submitted, request}
    assert :ok = Parlora.update_context(session, %{confirmed_order: "123"})
    assert_receive {:policy, outdated, _snapshot, _trigger}

    for index <- 1..12, do: inject(provider, :transcript_delta, caption("#{index}"))
    snapshot = Parlora.snapshot(session)
    assert snapshot.transcript_retention.dropped > 0
    assert snapshot.application_context == %{confirmed_order: "123"}
    assert snapshot.tasks[request.task_id].revision == 1
    assert snapshot.pending_delegations["work"].task_id == request.task_id
    assert :ok = FakeBackend.complete(backend, request, "Verified current result")
    assert_receive {:parlora_event, %Event{type: :request_completed}}
    send(outdated, {:decisions, []})
    assert_receive {:policy, fresh, current, _trigger}
    assert hd(current.transcripts).delta == "12"
    assert current.transcript_retention == snapshot.transcript_retention
    refute_receive {:context, _unapproved}, 20
    send(fresh, {:decisions, []})
    assert_receive {:context, %{content: "Verified current result"}}
    assert Parlora.status(session).retention.records.jobs == 1
    refute_received {:submitted, _replayed}
  end

  test "the default session survives more than 8192 deltas with bounded current history" do
    {session, provider, _backend} = boot(8_192, {PassivePolicy, []}, event_sink: nil)

    for index <- 1..10_000,
        do: MemoryAudio.inject(provider, :transcript_delta, caption("#{index}"))

    snapshot = Parlora.snapshot(session)
    assert Parlora.status(session).status == :ready
    history = snapshot.transcript_retention
    assert history.mode == :rolling
    assert history.retained + history.dropped == 10_000
    assert history.dropped > 0
    assert history.retained <= 8_192
    assert length(snapshot.transcripts) == history.retained
    assert hd(snapshot.transcripts).delta == "10000"
    status = Parlora.status(session)
    assert status.status == :ready
    assert status.retention.transcripts.retained_bytes <= status.retention.transcripts.max_bytes
  end

  test "explicit close mode retains the previous session exhaustion contract" do
    {session, provider, _backend} = boot(2, {PassivePolicy, []}, transcript_retention: :close)
    monitor = Process.monitor(session)

    for delta <- ["one", "two", "three"],
        do: MemoryAudio.inject(provider, :transcript_delta, caption(delta))

    assert_receive {:parlora_event,
                    %Event{type: :failed, payload: %{error: %{code: :backpressure}}}}

    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
  end

  defp state(count, bytes, mode \\ :rolling) do
    %State{
      limits: %Limits{max_transcripts: count, max_transcript_bytes: bytes},
      context: %ContextSnapshot{
        provider_generation: 0,
        transcript_retention: %{%ContextSnapshot{}.transcript_retention | mode: mode}
      },
      init: %Parlora.AdapterInit{
        session_id: "retention",
        adapter_id: "retention",
        generation: 0,
        event_sink: self(),
        limits: %Limits{}
      }
    }
  end

  defp caption(text), do: %{speaker: :user, delta: text, start_ms: nil, end_ms: nil}

  defp inject(provider, type, payload) do
    assert :ok = MemoryAudio.inject(provider, type, payload)
    assert_receive {:parlora_event, %Event{source: :provider, type: ^type}}
  end

  defp boot(count, policy, overrides \\ []) do
    {:ok, session} =
      Parlora.start_session(
        Keyword.merge(
          [
            channel: {MemoryChannel, observer: self()},
            provider: {MemoryProvider, observer: self()},
            backend: {FakeBackend, observer: self()},
            context_policy: policy,
            event_sink: self(),
            limits: [max_transcripts: count, shutdown_timeout_ms: 200]
          ],
          overrides
        )
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:adapter, :channel, _channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert Parlora.snapshot(session).transcript_retention.retained == 0
    # Adapter callbacks may precede their owner's completion handshake.
    await_ready(session)
    {session, provider, backend}
  end

  defp await_ready(session, attempts \\ 1_000)
  defp await_ready(session, 0), do: assert(Parlora.status(session).status == :ready)

  defp await_ready(session, attempts) do
    if Parlora.status(session).status != :ready do
      Process.sleep(1)
      await_ready(session, attempts - 1)
    end
  end
end
