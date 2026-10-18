defmodule Parlora.RuntimeCommandsTest do
  use ExUnit.Case, async: true
  alias Parlora.{ContextUpdate, Event}
  alias Parlora.Session.Uncertainty
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, OrderPolicy}

  defmodule Audit do
    def enter(kind, payload) do
      options = Process.get(:runtime_commands_test)
      send(options[:observer], {:invoked, kind, self(), payload})

      case options[:mode] do
        ^kind ->
          send(options[:observer], {:blocked_command, kind, self()})
          receive do: ({:release, ^kind} -> :ok)

        {:raise, ^kind} ->
          raise "runtime-private-marker"

        {:throw, ^kind} ->
          throw("runtime-private-marker")

        {:exit, ^kind} ->
          exit("runtime-private-marker")

        _other ->
          :ok
      end
    end
  end

  defmodule Backend do
    def start_link(init, options) do
      Process.put(:runtime_commands_test, options)
      FakeBackend.start_link(init, options)
    end

    def submit(pid, request) do
      Audit.enter(:submit, request)
      FakeBackend.submit(pid, request)
    end

    def cancel(pid, id, request, reason) do
      Audit.enter(:cancel, id)
      FakeBackend.cancel(pid, id, request, reason)
    end

    def update(pid, id, request, replacement) do
      Audit.enter(:update, id)
      FakeBackend.update(pid, id, request, replacement)
    end

    defdelegate close(pid, id, reason), to: FakeBackend
  end

  defmodule Provider do
    def start_link(init, options) do
      Process.put(:runtime_commands_test, options)
      MemoryAudio.start_link(init, :provider, options)
    end

    def append_context(pid, update) do
      Audit.enter(:append, update)
      MemoryAudio.append_context(pid, update)
    end

    def control(pid, id, command) do
      Audit.enter(:control, id)
      MemoryAudio.control(pid, id, command)
    end

    defdelegate read_audio(pid, budget), to: MemoryAudio
    defdelegate write_audio(pid, frame), to: MemoryAudio
    defdelegate close(pid, id, reason), to: MemoryAudio
  end

  test "a stalled backend submit cannot block status, progress deadlines or explicit close" do
    {pid, state} = boot(backend: :submit)
    delegate(state)
    assert_receive {:blocked_command, :submit, owner}
    assert owner == state.startup.owners.backend.owner
    assert Parlora.status(pid).status == :ready
    assert :ok = Parlora.expect_progress(pid, "still-responsive", 20, until: :explicit)

    assert_receive {:parlora_event,
                    %Event{type: :progress_changed, payload: %{status: :timed_out}}},
                   300

    assert :ok = Parlora.close(pid)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 500
    assert_down(state, pid)
    refute_received {:submitted, _request}
  end

  test "a stalled submit expires at the job deadline and preserves an uncertain outcome" do
    {pid, state} = boot([backend: :submit], job_timeout_ms: 100)
    delegate(state)
    assert_receive {:blocked_command, :submit, _owner}
    assert_receive {:parlora_event, %Event{source: :session, type: :request_uncertain}}, 400

    assert_receive {:parlora_event, %Event{source: :session, type: :closed, payload: payload}},
                   500

    assert Map.values(payload.jobs) == [:uncertain]
    assert_down(state, pid)
    refute_received {:submitted, _request}
  end

  test "a pending public context command cannot block snapshot or close and replies as uncertain" do
    {pid, state} = boot(provider: :append)
    client = Task.async(fn -> Parlora.append_context(pid, update("public")) end)
    assert_receive {:blocked_command, :append, _owner}
    assert %{session_id: _id} = Parlora.snapshot(pid)
    assert Parlora.status(pid).status == :ready
    assert :ok = Parlora.close(pid)
    assert {:error, %{details: %{outcome: :unknown}}} = Task.await(client)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 500
    assert_down(state, pid)
  end

  test "duplicate pending cancellation IDs execute once and share the actual admission outcome" do
    {pid, state} = boot([backend: :cancel], max_subscribers: 2)
    delegate(state)
    assert_receive {:submitted, request}
    first = Task.async(fn -> Parlora.cancel(pid, request.id, :caller, "cancel-once") end)
    assert_receive {:blocked_command, :cancel, owner}
    assert_receive {:invoked, :cancel, ^owner, "cancel-once"}
    second = Task.async(fn -> Parlora.cancel(pid, request.id, :caller, "cancel-once") end)

    eventually(fn ->
      commands = :sys.get_state(pid).startup.commands
      Enum.any?(commands.records, fn {_ref, r} -> match?([_, _], r.callers) end)
    end)

    assert {:error, %{code: :invalid_argument}} =
             Parlora.cancel(pid, request.id, :different, "cancel-once")

    assert {:error, %{code: :backpressure}} =
             Parlora.cancel(pid, request.id, :caller, "cancel-once")

    send(owner, {:release, :cancel})
    assert :ok = Task.await(first)
    assert :ok = Task.await(second)
    refute_received {:invoked, :cancel, _owner, "cancel-once"}
    assert :ok = Parlora.cancel(pid, request.id, :caller, "cancel-once")
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "cancelling a backend command before invocation prevents the external work" do
    {pid, state} = boot(backend: :submit)
    delegate(state)
    assert_receive {:blocked_command, :submit, owner}
    provider = elem(state.adapters.provider, 1)

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: " actually order 124"
    })

    eventually(fn -> map_size(Parlora.status(pid).jobs) == 2 end)

    {_id, queued} =
      Enum.find(:sys.get_state(pid).jobs, fn {_id, job} -> job.request.task_revision == 2 end)

    assert queued.admission == :pending
    assert :ok = Parlora.cancel(pid, queued.request.id, :caller, "cancel-queued")
    assert Parlora.status(pid).jobs[queued.request.id].status == :cancelled
    send(owner, {:release, :submit})
    assert_receive {:submitted, first}
    assert first.task_revision == 1
    eventually(fn -> map_size(:sys.get_state(pid).startup.commands.records) == 0 end)
    refute_received {:invoked, :submit, _owner, %{task_revision: 2}}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "provider commands keep ordering and a queued obsolete result is never invoked" do
    {pid, state} = boot(provider: :control)
    client = Task.async(fn -> Parlora.control(pid, {:input_muted, true}, "hold-provider") end)
    assert_receive {:blocked_command, :control, owner}
    delegate(state)
    assert_receive {:submitted, first}
    backend = elem(state.adapters.backend, 1)
    provider = elem(state.adapters.provider, 1)
    FakeBackend.complete(backend, first, "Obsolete result")
    eventually(fn -> Parlora.status(pid).jobs[first.id].delivery == :awaiting_provider end)

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: " actually order 124"
    })

    assert_receive {:submitted, second}
    send(owner, {:release, :control})
    assert :ok = Task.await(client)
    FakeBackend.complete(backend, second, "Current result")
    assert_receive {:context, %{content: "Current result"}}
    refute_received {:invoked, :append, _owner, %{content: "Obsolete result"}}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "early backend results and acknowledgements cannot be overwritten by admission replies" do
    {pid, state} = boot([])
    delegate(state)
    assert_receive {:submitted, request}
    FakeBackend.complete(elem(state.adapters.backend, 1), request, "Verified")
    assert_receive {:context, %{content: "Verified"}}

    eventually(fn ->
      job = Parlora.status(pid).jobs[request.id]
      job.status == :completed and job.delivery == :accepted
    end)

    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "delegation cancellation discards a queued result without discarding unrelated context" do
    {pid, state} = boot(provider: :control)
    {client, owner} = hold_provider(pid)
    delegate(state)
    assert_receive {:submitted, request}
    FakeBackend.complete(elem(state.adapters.backend, 1), request, "Cancelled answer")
    eventually(fn -> Parlora.status(pid).jobs[request.id].delivery == :awaiting_provider end)
    cancel_delegation(pid, state)
    other = Task.async(fn -> Parlora.append_context(pid, update("Unrelated context")) end)

    send(owner, {:release, :control})
    assert :ok = Task.await(client)
    assert :ok = Task.await(other)
    assert_receive {:context, %{content: "Unrelated context"}}
    eventually(fn -> Parlora.status(pid).jobs[request.id].delivery == :stale end)
    refute_received {:invoked, :append, _owner, %{content: "Cancelled answer"}}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "delegation cancellation also discards a queued uncertainty notice" do
    {pid, state} = boot(provider: :control)
    {client, owner} = hold_provider(pid)
    delegate(state)
    assert_receive {:submitted, request}
    mark_uncertain(pid, state, request)
    cancel_delegation(pid, state)

    send(owner, {:release, :control})
    assert :ok = Task.await(client)
    eventually(fn -> Parlora.status(pid).jobs[request.id].uncertainty_delivery == :stale end)
    refute_received {:invoked, :append, _owner, _update}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "cancelling the old delegation revision does not suppress a subsequent order correction" do
    {pid, state} = boot(provider: :control)
    {client, owner} = hold_provider(pid)
    delegate(state)
    assert_receive {:submitted, first}
    backend = elem(state.adapters.backend, 1)
    FakeBackend.complete(backend, first, "Old order answer")
    eventually(fn -> Parlora.status(pid).jobs[first.id].delivery == :awaiting_provider end)
    cancel_delegation(pid, state)

    MemoryAudio.inject(elem(state.adapters.provider, 1), :transcript_delta, %{
      speaker: :user,
      delta: " actually order 124"
    })

    assert_receive {:submitted, second}
    assert second.task_revision == first.task_revision + 1
    assert second.delegation_id == first.delegation_id
    FakeBackend.complete(backend, second, "Corrected order answer")
    eventually(fn -> Parlora.status(pid).jobs[second.id].delivery == :awaiting_provider end)
    send(owner, {:release, :control})
    assert :ok = Task.await(client)
    assert_receive {:context, %{content: "Corrected order answer", delegation_id: nil}}

    eventually(fn ->
      jobs = Parlora.status(pid).jobs
      jobs[first.id].delivery == :stale and jobs[second.id].delivery == :accepted
    end)

    refute_received {:invoked, :append, _owner, %{content: "Old order answer"}}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "an order correction discards a queued uncertainty notice and delivers the new result" do
    {pid, state} = boot(provider: :control)
    {client, owner} = hold_provider(pid)
    delegate(state)
    assert_receive {:submitted, first}
    mark_uncertain(pid, state, first)

    MemoryAudio.inject(elem(state.adapters.provider, 1), :transcript_delta, %{
      speaker: :user,
      delta: " actually order 124"
    })

    assert_receive {:submitted, second}
    FakeBackend.complete(elem(state.adapters.backend, 1), second, "Corrected order answer")
    eventually(fn -> Parlora.status(pid).jobs[second.id].delivery == :awaiting_provider end)
    send(owner, {:release, :control})
    assert :ok = Task.await(client)
    assert_receive {:context, %{content: "Corrected order answer"}}

    eventually(fn ->
      jobs = Parlora.status(pid).jobs
      jobs[first.id].uncertainty_delivery == :stale and jobs[second.id].delivery == :accepted
    end)

    uncertainty = Uncertainty.message()
    refute_received {:invoked, :append, _owner, %{content: ^uncertainty}}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  for outcome <- [:completed, :failed, :cancelled] do
    @outcome outcome
    test "a late #{@outcome} result supersedes an uncertainty notice still queued for dispatch" do
      {pid, state} = boot(provider: :control)
      {client, owner} = hold_provider(pid)
      delegate(state)
      assert_receive {:submitted, request}
      mark_uncertain(pid, state, request)
      backend = elem(state.adapters.backend, 1)
      FakeBackend.complete(backend, request, "Verified terminal answer", @outcome)
      eventually(fn -> Parlora.status(pid).jobs[request.id].delivery == :awaiting_provider end)

      send(owner, {:release, :control})
      assert :ok = Task.await(client)
      assert_receive {:context, %{content: "Verified terminal answer"}}

      eventually(fn ->
        job = Parlora.status(pid).jobs[request.id]

        job.status == @outcome and job.delivery == :accepted and
          job.uncertainty_delivery == :superseded
      end)

      uncertainty = Uncertainty.message()
      refute_received {:invoked, :append, _owner, %{content: ^uncertainty}}
      refute_received {:submitted, _replayed_request}
      assert :ok = Parlora.close(pid)
      assert_down(state, pid)
    end
  end

  test "a still-current queued uncertainty notice is delivered once" do
    {pid, state} = boot(provider: :control)
    {client, owner} = hold_provider(pid)
    delegate(state)
    assert_receive {:submitted, request}
    mark_uncertain(pid, state, request)
    send(owner, {:release, :control})
    assert :ok = Task.await(client)
    uncertainty = Uncertainty.message()
    assert_receive {:context, %{content: ^uncertainty}}
    eventually(fn -> Parlora.status(pid).jobs[request.id].uncertainty_delivery == :accepted end)

    FakeBackend.inject(elem(state.adapters.backend, 1), :request_uncertain, %{},
      request_id: request.id
    )

    assert Parlora.status(pid).jobs[request.id].status == :uncertain
    refute_received {:context, _duplicate_notice}
    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "a notice already dispatched retains its acknowledgment when a result arrives" do
    {pid, state} = boot(provider: :append)
    delegate(state)
    assert_receive {:submitted, request}
    mark_uncertain(pid, state, request)
    assert_receive {:blocked_command, :append, owner}
    FakeBackend.complete(elem(state.adapters.backend, 1), request, "Verified after dispatch")
    eventually(fn -> Parlora.status(pid).jobs[request.id].delivery == :awaiting_provider end)
    send(owner, {:release, :append})
    uncertainty = Uncertainty.message()
    assert_receive {:context, %{content: ^uncertainty}}
    assert_receive {:blocked_command, :append, ^owner}
    send(owner, {:release, :append})
    assert_receive {:context, %{content: "Verified after dispatch"}}

    eventually(fn ->
      job = Parlora.status(pid).jobs[request.id]
      job.delivery == :accepted and job.uncertainty_delivery == :accepted
    end)

    assert :ok = Parlora.close(pid)
    assert_down(state, pid)
  end

  test "command queue admission is bounded and queued commands are not invoked on close" do
    {pid, state} = boot([provider: :control], max_records: 3)
    client = Task.async(fn -> Parlora.control(pid, {:input_muted, true}, "hold") end)
    assert_receive {:blocked_command, :control, _owner}

    observers =
      for id <- ["queued-1", "queued-2"],
          do: Task.async(fn -> Parlora.append_context(pid, update(id)) end)

    eventually(fn -> map_size(:sys.get_state(pid).startup.commands.records) == 3 end)
    assert {:error, %{code: :backpressure}} = Parlora.append_context(pid, update("overflow"))
    assert :ok = Parlora.close(pid)
    assert {:error, %{details: %{outcome: :unknown}}} = Task.await(client)

    for observer <- observers do
      assert {:error, %{details: %{execution: :never_submitted}}} = Task.await(observer)
    end

    assert_down(state, pid)
    refute_received {:invoked, :append, _owner, _update}
  end

  test "exceptions, throws and exits are sanitized without crashing the coordinator" do
    for kind <- [:raise, :throw, :exit] do
      {pid, state} = boot(provider: {kind, :append})
      assert {:error, error} = Parlora.append_context(pid, update("private"))
      refute inspect(error) =~ "runtime-private-marker"
      assert error.details.outcome == :unknown
      assert Parlora.status(pid).status == :ready
      assert :ok = Parlora.close(pid)
      assert_down(state, pid)
    end
  end

  defp update(id),
    do: %ContextUpdate{id: id, kind: :speakable, content: id, provider_generation: 0}

  defp hold_provider(pid) do
    client = Task.async(fn -> Parlora.control(pid, {:input_muted, true}, "hold-provider") end)
    assert_receive {:blocked_command, :control, owner}
    {client, owner}
  end

  defp cancel_delegation(pid, state) do
    MemoryAudio.inject(elem(state.adapters.provider, 1), :delegation_cancelled, %{id: "work"})

    eventually(fn ->
      :sys.get_state(pid).context.pending_delegations["work"].status == :cancelled
    end)
  end

  defp mark_uncertain(pid, state, request) do
    FakeBackend.inject(
      elem(state.adapters.backend, 1),
      :request_uncertain,
      %{reason: :observer_exited},
      request_id: request.id
    )

    eventually(fn ->
      Parlora.status(pid).jobs[request.id][:uncertainty_delivery] == :awaiting_provider
    end)
  end

  defp delegate(state) do
    provider = elem(state.adapters.provider, 1)
    :ok = MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "order 123"})
    :ok = MemoryAudio.inject(provider, :delegation_requested, %{id: "work", offset_ms: 0})
  end

  defp boot(modes, limits \\ []) do
    {:ok, pid} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {Provider, observer: self(), mode: modes[:provider]},
        backend: {Backend, observer: self(), mode: modes[:backend]},
        context_policy: {OrderPolicy, []},
        event_sink: self(),
        limits: Keyword.merge([startup_timeout_ms: 2_000, shutdown_timeout_ms: 100], limits)
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, 1_000
    {pid, :sys.get_state(pid)}
  end

  defp assert_down(state, pid) do
    pids =
      [pid, state.input_pipeline, state.output_pipeline] ++
        Enum.map(state.adapters, fn {_role, {_module, pid}} -> pid end) ++
        Enum.flat_map(state.startup.owners, fn {_role, o} -> [o.owner, o.watcher] end)

    for pid <- pids do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
