defmodule Parlora.SessionHealthTest do
  use ExUnit.Case, async: true

  # Observe asynchronous startup/teardown with CI scheduling headroom. The actual
  # session deadlines below stay short and are checked independently.
  @lifecycle_timeout 5_000
  alias Parlora.{AudioFrame, ContextUpdate, Error, Event}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, MemoryProvider, OrderPolicy}

  defp session(options \\ []) do
    {:ok, pid} =
      Parlora.start_session(
        Keyword.merge(
          [
            channel: {MemoryChannel, observer: self()},
            provider: {MemoryProvider, observer: self()},
            backend: {FakeBackend, observer: self()},
            context_policy: {OrderPolicy, []},
            event_sink: self()
          ],
          options
        )
      )

    on_exit(fn -> if Process.alive?(pid), do: Parlora.close(pid) end)
    assert_receive {:adapter, :channel, channel}, @lifecycle_timeout
    assert_receive {:adapter, :provider, provider}, @lifecycle_timeout
    assert_receive {:adapter, :backend, backend}, @lifecycle_timeout
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, @lifecycle_timeout
    {pid, channel, provider, backend}
  end

  defp caption(provider, speaker, delta) do
    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: speaker,
      delta: delta,
      start_ms: 0,
      end_ms: 100
    })
  end

  defp changed(id, status) do
    assert_receive {:parlora_event,
                    %Event{
                      source: :session,
                      type: :progress_changed,
                      payload: %{id: ^id, status: ^status}
                    }}
  end

  test "idle ready sessions have no implicit deadline; numeric counters omit content" do
    {pid, channel, provider, _backend} = session()
    assert Parlora.status(pid).health.expectation == nil
    assert Parlora.status(pid).health.input_forwarded.last_at_us == nil
    frame = AudioFrame.pcm(:binary.copy(<<12, 0>>, 240), "private-stream", 0)
    :ok = MemoryAudio.audio(channel, frame)
    :ok = MemoryAudio.audio(provider, frame)
    caption(provider, :user, "private words")

    eventually(fn ->
      health = Parlora.status(pid).health

      health.input_forwarded.frames == 1 and health.output_forwarded.frames == 1 and
        health.observations.user_caption.count == 1
    end)

    health = Parlora.status(pid).health
    assert health.input_forwarded.bytes == 480
    assert health.output_forwarded.bytes == 480
    assert health.observations.user_caption.count == 1
    refute inspect(health) =~ "private"
    refute_receive {:parlora_event, %Event{type: :failed}}, 80
    assert Parlora.status(pid).status == :ready
  end

  test "acknowledged commands and continuing input do not satisfy response expectation" do
    {pid, channel, _provider, _backend} = session(limits: [shutdown_timeout_ms: 100])
    :ok = Parlora.expect_progress(pid, "opening", 100, on_timeout: :close)

    :ok =
      Parlora.append_context(pid, %ContextUpdate{
        id: "instruction",
        kind: :instruction,
        content: "Greet",
        provider_generation: 0
      })

    assert_receive {:parlora_event, %Event{type: :context_acknowledged}}
    :ok = MemoryAudio.audio(channel, AudioFrame.pcm(:binary.copy(<<0, 0>>, 240), "input", 0))
    changed("opening", :timed_out)
    assert_receive {:parlora_event, %Event{type: :failed, payload: %{cause: :progress_timeout}}}
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, @lifecycle_timeout

    for process <- [pid, channel] do
      ref = Process.monitor(process)
      assert_receive {:DOWN, ^ref, :process, ^process, _reason}, @lifecycle_timeout
    end

    {fresh, _, _, _} = session(context: %{previous_order: "124"})
    assert Parlora.snapshot(fresh).tasks == %{}
    refute_receive {:submitted, _}, 30
  end

  test "only requested nonblank speaker progress resolves; duplicates never renew" do
    {pid, _channel, provider, _backend} = session()
    :ok = Parlora.expect_progress(pid, "reply", 300)
    deadline = Parlora.status(pid).health.expectation.deadline_at_us
    :ok = Parlora.expect_progress(pid, "reply", 300)
    assert deadline == Parlora.status(pid).health.expectation.deadline_at_us
    caption(provider, :user, "hello")
    caption(provider, :assistant, " ")
    assert Parlora.status(pid).health.expectation.status == :pending
    caption(provider, :assistant, "Hello")
    changed("reply", :observed)
    :ok = Parlora.expect_progress(pid, "reply", 300)
    assert Parlora.status(pid).health.expectation.status == :observed

    refute_receive {:parlora_event,
                    %Event{type: :progress_changed, payload: %{status: :timed_out}}},
                   350
  end

  test "notify expiry preserves session and a new ID starts independently" do
    {pid, _, provider, _} = session()
    :ok = Parlora.expect_progress(pid, "first", 20)
    changed("first", :timed_out)
    assert Parlora.status(pid).status == :ready
    caption(provider, :assistant, "late")
    assert Parlora.status(pid).health.expectation.status == :timed_out
    assert {:error, %Error{code: :invalid_argument}} = Parlora.resolve_progress(pid, "first")
    :ok = Parlora.expect_progress(pid, "second", 100, until: :user_caption)
    caption(provider, :user, "new")
    changed("second", :observed)
  end

  test "explicit completion cannot be inferred from transcripts or acknowledgments" do
    {pid, _, provider, _} = session()
    :ok = Parlora.expect_progress(pid, "task", 300, until: :explicit)
    caption(provider, :assistant, "One moment")
    assert Parlora.status(pid).health.expectation.status == :pending
    :ok = Parlora.resolve_progress(pid, "task")
    :ok = Parlora.resolve_progress(pid, "task")
    changed("task", :completed)
    assert {:error, %Error{}} = Parlora.resolve_progress(pid, "task", :cancelled)
  end

  test "cancellation and stale timers cannot terminate a subsequent expectation" do
    {pid, _, provider, _} = session()
    :ok = Parlora.expect_progress(pid, "old", 30, on_timeout: :close)
    token = :sys.get_state(pid).health.token
    :ok = Parlora.resolve_progress(pid, "old", :cancelled)
    changed("old", :cancelled)
    :ok = Parlora.expect_progress(pid, "new", 300, on_timeout: :close)
    send(pid, {:progress_deadline, token})
    assert Parlora.status(pid).health.expectation.id == "new"
    caption(provider, :assistant, "new reply")
    changed("new", :observed)
    refute_receive {:parlora_event, %Event{type: :failed}}, 60
  end

  test "invalid settings, concurrent expectations and conflicting IDs are rejected" do
    {pid, _, _, _} = session()

    for {timeout, options} <- [
          {0, []},
          {300_001, []},
          {1, [unknown: true]},
          {1, [until: :audio]},
          {1, [on_timeout: :retry]},
          {1, [until: :explicit, until: :explicit]},
          {1, [:bad]}
        ] do
      assert {:error, %Error{code: :invalid_argument}} =
               Parlora.expect_progress(pid, "bad", timeout, options)
    end

    assert {:error, %Error{}} = Parlora.expect_progress(pid, "", 100)
    :ok = Parlora.expect_progress(pid, "active", 1_000)
    assert {:error, %Error{code: :backpressure}} = Parlora.expect_progress(pid, "other", 1_000)
    assert {:error, %Error{code: :invalid_argument}} = Parlora.expect_progress(pid, "active", 999)
    :ok = Parlora.resolve_progress(pid, "active", :cancelled)
    :ok = Parlora.expect_progress(pid, "other", 1_000)
  end

  test "record exhaustion stays bounded and closing cancels a pending deadline" do
    {pid, _, _, _} = session(limits: [max_records: 1])
    :ok = Parlora.expect_progress(pid, "one", 300)
    :ok = Parlora.resolve_progress(pid, "one")
    assert {:error, %Error{code: :backpressure}} = Parlora.expect_progress(pid, "two", 300)
    :ok = Parlora.expect_progress(pid, "one", 300)
    assert map_size(:sys.get_state(pid).health.commands.entries) == 1
    {other, _, _, _} = session()
    :ok = Parlora.expect_progress(other, "closing", 300, on_timeout: :close)
    :ok = Parlora.close(other)
    changed("closing", :cancelled)
    refute_receive {:parlora_event, %Event{type: :failed}}, 350
  end

  test "events from old adapters or before arming cannot satisfy a deadline" do
    {pid, _, provider, _} = session()
    init = :sys.get_state(provider).init

    event = %Event{
      source: :provider,
      session_id: init.session_id,
      adapter_id: init.adapter_id,
      generation: init.generation,
      type: :transcript_delta,
      observed_at_us: System.monotonic_time(:microsecond) - 1_000,
      payload: %{speaker: :assistant, delta: "old", start_ms: 0, end_ms: 1}
    }

    :ok = Parlora.expect_progress(pid, "new", 100)
    send(pid, {:parlora_event, event})

    send(
      pid,
      {:parlora_event,
       %{event | adapter_id: "old-adapter", observed_at_us: System.monotonic_time(:microsecond)}}
    )

    assert Parlora.status(pid).health.expectation.status == :pending
    changed("new", :timed_out)
  end

  test "conversation progress permits caller interruption and delegation" do
    {pid, _, provider, _} = session()
    :ok = Parlora.expect_progress(pid, "opening", 300, until: :conversation, on_timeout: :close)
    caption(provider, :user, "hello")
    changed("opening", :observed)
    :ok = Parlora.expect_progress(pid, "delegate", 300, until: :delegation)

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "request",
      target: :client,
      offset_ms: 0
    })

    changed("delegate", :observed)
  end

  test "queued captions cannot satisfy an elapsed deadline when scheduling resumes" do
    {pid, _, provider, _} = session(limits: [shutdown_timeout_ms: 100])
    :ok = Parlora.expect_progress(pid, "delayed", 40, on_timeout: :close)
    :sys.suspend(pid)

    try do
      caption(provider, :assistant, "queued before expiry")
      Process.sleep(60)
    after
      :sys.resume(pid)
    end

    changed("delayed", :timed_out)

    assert_receive {:parlora_event,
                    %Event{
                      source: :session,
                      type: :closed,
                      payload: %{health: %{expectation: %{status: :timed_out}}}
                    }},
                   @lifecycle_timeout
  end

  test "an early timer notification preserves the real deadline" do
    {pid, _, _, _} = session()
    :ok = Parlora.expect_progress(pid, "early", 50)
    token = :sys.get_state(pid).health.token
    send(pid, {:progress_deadline, token})
    assert Parlora.status(pid).health.expectation.status == :pending
    changed("early", :timed_out)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
