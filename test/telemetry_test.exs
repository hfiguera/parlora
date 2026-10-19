defmodule Parlora.TelemetryTest do
  use ExUnit.Case, async: false
  @lifecycle_timeout 5_000
  alias Parlora.{Event, Telemetry}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, MemoryProvider, OrderPolicy}

  defmodule InterruptibleProvider do
    use Parlora.TestSupport.MemoryAudio, role: :provider

    @impl true
    def resume_output(pid, token),
      do: MemoryAudio.inject(pid, :extension, %{token: token})
  end

  setup do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, Telemetry.events(), &__MODULE__.observe/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def observe(name, measurements, metadata, pid),
    do: send(pid, {:observation, name, measurements, metadata})

  defp boot(options \\ []) do
    {:ok, pid} =
      Parlora.start_session(
        Keyword.merge(
          [
            channel: {MemoryChannel, observer: self()},
            provider: {MemoryProvider, observer: self()},
            backend: {FakeBackend, observer: self()},
            context_policy: {OrderPolicy, []},
            event_sink: self(),
            instructions: "private-key-and-prompt"
          ],
          options
        )
      )

    on_exit(fn -> if Process.alive?(pid), do: Parlora.close(pid) end)
    {pid, Parlora.status(pid).session_id}
  end

  defp close(pid, id) do
    state = :sys.get_state(pid)
    # Closing is asynchronous. Its deadline bounds the operation; observing its
    # exit needs a separate scheduling allowance, even if cleanup uses the full
    # deadline while scanning for orphaned OTP descendants.
    timeout = state.limits.shutdown_timeout_ms + @lifecycle_timeout

    owned =
      for {_role, owner} <- state.startup.owners,
          process <- [owner.owner, owner.watcher],
          do: {process, Process.monitor(process)}

    ref = Process.monitor(pid)
    assert :ok = Parlora.close(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, timeout
    assert_receive {:observation, [:parlora, :session, :stop], _, %{session_id: ^id}}

    # Watchers finish their orphan sweeps after the coordinator exits. Do not
    # leave those sweeps competing with the next fixture's cleanup.
    for {process, monitor} <- owned do
      assert_receive {:DOWN, ^monitor, :process, ^process, _reason}, @lifecycle_timeout
    end
  end

  test "shutdown observation allows the configured deadline before its scheduling allowance" do
    {pid, id} =
      boot(
        channel: {MemoryChannel, observer: self(), no_close_event: true},
        # Exceed the suite's five-second receive timeout deliberately. A missing
        # close notification must exercise the real deadline, without leaving
        # only a few milliseconds for the test to observe the eventual exit.
        limits: [shutdown_timeout_ms: 6_000]
      )

    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    close(pid, id)

    assert_receive {:observation, [:parlora, :shutdown, :stop], _,
                    %{session_id: ^id, outcome: :timeout}}

    refute_received {:observation, [:parlora, :session, :stop], _, %{session_id: ^id}}
  end

  test "startup ends at readiness and shutdown measures actual coordinator cleanup" do
    {pid, id} = boot()
    assert_receive {:observation, [:parlora, :session, :start], start, %{session_id: ^id} = root}
    assert is_integer(start.system_time) and is_integer(start.monotonic_time)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    assert_receive {:observation, [:parlora, :startup, :stop], done,
                    %{session_id: ^id, outcome: :ready, parent_operation_id: parent}}

    assert parent == root.operation_id
    assert done.duration >= 0 and done.count == 1
    close(pid, id)

    assert_receive {:observation, [:parlora, :shutdown, :stop], _,
                    %{session_id: ^id, outcome: :completed}}

    refute_received {:observation, [:parlora, :session, :stop], _, %{session_id: ^id}}
  end

  test "startup deadline and forced shutdown have distinct outcomes without changing deadlines" do
    {pid, id} =
      boot(
        channel: {MemoryChannel, observer: self(), delay_ready: true},
        limits: [startup_timeout_ms: 50, shutdown_timeout_ms: 50]
      )

    ref = Process.monitor(pid)

    assert_receive {:observation, [:parlora, :startup, :stop], _,
                    %{session_id: ^id, outcome: :timeout}}

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:observation, [:parlora, :shutdown, :stop], _, %{session_id: ^id}}
    refute_received {:observation, [:parlora, :startup, :stop], _, %{session_id: ^id}}
  end

  test "backend execution, queue and delivery are separate and duplicate observations do not finish twice" do
    {pid, id} = boot()
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "private-key-and-prompt order 123",
      start_ms: 0,
      end_ms: 1
    })

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "delegation",
      target: :client,
      offset_ms: 1
    })

    assert_receive {:submitted, request}

    assert_receive {:observation, [:parlora, :backend_queue, :stop], _,
                    %{request_id: request_id, outcome: :started}}

    assert request_id == request.id
    assert_receive {:observation, [:parlora, :backend, :start], _, %{request_id: ^request_id}}
    FakeBackend.complete(backend, request, "private-key-and-prompt")

    assert_receive {:observation, [:parlora, :backend, :stop], _,
                    %{request_id: ^request_id, outcome: :completed}}

    assert_receive {:observation, [:parlora, :delivery, :stop], _,
                    %{request_id: ^request_id, outcome: :accepted}}

    FakeBackend.complete(backend, request, "private-key-and-prompt")
    close(pid, id)
    refute_received {:observation, [:parlora, :backend, :stop], _, %{request_id: ^request_id}}
    refute_received {:observation, [:parlora, :delivery, :stop], _, %{request_id: ^request_id}}

    for {:observation, _name, measurements, metadata} <- drain() do
      refute inspect({measurements, metadata}) =~ "private-key-and-prompt"
      refute Map.has_key?(metadata, :input)
    end
  end

  test "runtime observations allowlist fields and skip transcripts, arbitrary extensions and error details" do
    secret = "private-key-and-prompt"

    Telemetry.event(%Event{
      session_id: "test",
      source: :backend,
      type: :request_uncertain,
      payload: %{
        error: Parlora.Error.new(:unknown, secret, %{api_key: secret}),
        reason: secret,
        input: %{password: secret},
        task_id: "task",
        task_revision: 2
      }
    })

    assert_receive {:observation, [:parlora, :runtime, :event], %{count: 1}, metadata}
    assert metadata.task_revision == 2
    refute inspect(metadata) =~ secret
    Telemetry.event(%Event{type: :transcript_delta, payload: %{delta: secret}})
    Telemetry.event(%Event{type: :extension, payload: %{api_key: secret}})
    refute_received {:observation, _, _, _}
  end

  test "queue cancellation does not invent backend execution, and shutdown deadline is visible" do
    {pid, id} =
      boot(
        limits: [max_jobs: 1, shutdown_timeout_ms: 50],
        channel: {MemoryChannel, observer: self(), no_close_event: true}
      )

    assert_receive {:adapter, :provider, provider}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "order 123",
      start_ms: 0,
      end_ms: 1
    })

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "first",
      target: :client,
      offset_ms: 1
    })

    assert_receive {:submitted, first}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: " actually order 124",
      start_ms: 1,
      end_ms: 2
    })

    assert_receive {:parlora_event, %Event{type: :task_queued, request_id: queued}}
    assert :ok = Parlora.cancel(pid, queued, :test, "cancel-queued")

    assert_receive {:observation, [:parlora, :backend_queue, :stop], _,
                    %{request_id: ^queued, outcome: :cancelled}}

    refute_received {:observation, [:parlora, :backend, :start], _, %{request_id: ^queued}}
    close(pid, id)

    assert_receive {:observation, [:parlora, :shutdown, :stop], _,
                    %{session_id: ^id, outcome: :timeout}}

    assert_receive {:observation, [:parlora, :backend, :stop], _,
                    %{request_id: request_id, outcome: :uncertain}}

    assert request_id == first.id
  end

  test "correction suppresses the obsolete delivery without suppressing current instrumentation" do
    {pid, id} = boot()
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "order 123",
      start_ms: 0,
      end_ms: 1
    })

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "correction",
      target: :client,
      offset_ms: 1
    })

    assert_receive {:submitted, first}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: " actually order 124",
      start_ms: 1,
      end_ms: 2
    })

    assert_receive {:submitted, current}
    assert current.task_revision == 2
    FakeBackend.complete(backend, first, "old private result")

    assert_receive {:observation, [:parlora, :delivery, :stop], _,
                    %{request_id: old_id, outcome: :stale}}

    assert old_id == first.id
    FakeBackend.complete(backend, current, "current private result")

    assert_receive {:observation, [:parlora, :delivery, :stop], _,
                    %{request_id: current_id, outcome: :accepted}}

    assert current_id == current.id
    close(pid, id)
  end

  test "policy timeout closes its operation and monitoring handler failure cannot stop a session" do
    {pid, id} =
      boot(
        context_policy: {Parlora.TestSupport.ControlledPolicy, observer: self()},
        limits: [policy_timeout_ms: 50]
      )

    assert_receive {:adapter, :provider, provider}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "private request",
      start_ms: 0,
      end_ms: 1
    })

    assert_receive {:observation, [:parlora, :policy, :stop], _,
                    %{session_id: ^id, outcome: :timeout}}

    close(pid, id)
    handler = {__MODULE__, :broken, make_ref()}
    :ok = :telemetry.attach(handler, [:parlora, :startup, :stop], &__MODULE__.broken/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    {other, other_id} = boot()
    assert_receive {:parlora_event, %Event{source: :session, type: :ready, session_id: ^other_id}}
    assert Process.alive?(other)
    assert :telemetry.list_handlers([:parlora, :startup, :stop]) |> Enum.all?(&(&1.id != handler))
    close(other, other_id)
  end

  test "uncertainty finishes observation once and a later verified result can still be delivered" do
    {pid, id} = boot()
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "order 123",
      start_ms: 0,
      end_ms: 1
    })

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "uncertain",
      target: :client,
      offset_ms: 1
    })

    assert_receive {:submitted, request}
    request_id = request.id

    FakeBackend.inject(backend, :request_uncertain, %{reason: :execution_deadline},
      request_id: request_id
    )

    assert_receive {:observation, [:parlora, :backend, :stop], _,
                    %{request_id: ^request_id, outcome: :uncertain}}

    FakeBackend.complete(backend, request, "verified result")

    assert_receive {:observation, [:parlora, :delivery, :stop], _,
                    %{request_id: ^request_id, outcome: :accepted}}

    # An adapter's delayed start cannot reopen a terminal execution observation.
    FakeBackend.inject(backend, :request_started, %{task_revision: request.task_revision},
      request_id: request_id
    )

    close(pid, id)
    refute_received {:observation, [:parlora, :backend, :stop], _, %{request_id: ^request_id}}
  end

  test "recovery timing finishes only for the matching token" do
    {pid, id} = boot()
    assert_receive {:adapter, :provider, provider}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    MemoryAudio.inject(provider, :output_recovery_requested, %{token: 1, cause: :output_overflow})
    assert_receive {:output_recovery, 1, _snapshot}
    assert_receive {:observation, [:parlora, :recovery, :start], _, %{session_id: ^id}}
    MemoryAudio.inject(provider, :output_recovered, %{token: 0})
    _status = Parlora.status(pid)
    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}
    MemoryAudio.inject(provider, :output_recovered, %{token: 1})

    assert_receive {:observation, [:parlora, :recovery, :stop], _,
                    %{session_id: ^id, outcome: :reconnected}}

    refute Map.has_key?(Parlora.status(pid).output_recovery, :telemetry)
    close(pid, id)
    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}
  end

  test "duplicate completions cannot finish recovery twice or change a newer recovery" do
    {pid, id} = boot()
    assert_receive {:adapter, :provider, provider}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    MemoryAudio.inject(provider, :output_recovery_requested, %{token: 1, cause: :output_overflow})
    assert_receive {:output_recovery, 1, _snapshot}
    assert_receive {:observation, [:parlora, :recovery, :start], _, %{session_id: ^id} = first}
    MemoryAudio.inject(provider, :output_recovered, %{token: 1})

    assert_receive {:observation, [:parlora, :recovery, :stop], _,
                    %{session_id: ^id, operation_id: first_operation, outcome: :reconnected}}

    assert first_operation == first.operation_id
    recovered = Parlora.status(pid).output_recovery
    assert recovered.stage == :awaiting_user

    MemoryAudio.inject(provider, :output_recovered, %{token: 1})
    assert Parlora.status(pid).output_recovery == recovered
    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}

    MemoryAudio.inject(provider, :output_recovery_requested, %{token: 2, cause: :output_overflow})
    assert_receive {:output_recovery, 2, _snapshot}
    assert_receive {:observation, [:parlora, :recovery, :start], _, %{session_id: ^id} = second}
    assert second.operation_id != first_operation
    reconnecting = Parlora.status(pid).output_recovery
    assert reconnecting.stage == :reconnecting

    MemoryAudio.inject(provider, :output_recovered, %{token: 1})
    assert Parlora.status(pid).output_recovery == reconnecting
    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}
    MemoryAudio.inject(provider, :output_recovered, %{token: 2})

    assert_receive {:observation, [:parlora, :recovery, :stop], _,
                    %{session_id: ^id, operation_id: second_operation, outcome: :reconnected}}

    assert second_operation == second.operation_id
    assert Parlora.status(pid).output_recovery.stage == :awaiting_user
    close(pid, id)
    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}
  end

  test "late recovery completion during shutdown cannot change state or restart its deadline" do
    {pid, id} =
      boot(channel: {MemoryChannel, observer: self(), no_close_event: true})

    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    provider_init = :sys.get_state(provider).init
    channel_init = :sys.get_state(channel).init
    MemoryAudio.inject(provider, :output_recovery_requested, %{token: 1, cause: :output_overflow})
    assert_receive {:output_recovery, 1, _snapshot}
    assert_receive {:observation, [:parlora, :recovery, :start], _, %{session_id: ^id} = recovery}
    ref = Process.monitor(pid)
    assert :ok = Parlora.close(pid)
    closing = Parlora.status(pid)
    timer = :sys.get_state(pid).shutdown_timer
    assert closing.status == :closing
    assert closing.output_recovery.stage == :reconnecting

    assert_receive {:observation, [:parlora, :recovery, :stop], _,
                    %{session_id: ^id, operation_id: operation, outcome: :closed}}

    assert operation == recovery.operation_id

    # Deliver an observation retained before the provider was closed. The open
    # channel keeps shutdown pending without sleeping or racing the deadline.
    Event.emit(provider_init, :provider, :output_recovered, %{token: 1})
    after_late = Parlora.status(pid)
    assert after_late.status == :closing
    assert after_late.output_recovery == closing.output_recovery
    assert :sys.get_state(pid).shutdown_timer == timer
    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}

    Event.emit(channel_init, :channel, :closed)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert_receive {:observation, [:parlora, :shutdown, :stop], _,
                    %{session_id: ^id, outcome: :completed}}

    refute_received {:observation, [:parlora, :recovery, :stop], _, %{session_id: ^id}}
  end

  test "interruption timing includes the clear barrier and completed resume command" do
    {pid, id} = boot(provider: {InterruptibleProvider, observer: self()})
    assert_receive {:adapter, :provider, provider}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    MemoryAudio.inject(provider, :output_interrupted, %{token: 1})

    assert_receive {:observation, [:parlora, :interruption, :stop], %{duration: duration},
                    %{session_id: ^id, outcome: :completed}}

    assert duration >= 0
    close(pid, id)
  end

  def broken(_name, _measurements, _metadata, _config), do: raise("Exporter unavailable")

  defp drain do
    receive do
      message -> [message | drain()]
    after
      0 -> []
    end
  end
end
