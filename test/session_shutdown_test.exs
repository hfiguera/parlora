defmodule Parlora.SessionShutdownTest do
  # These tests measure real shutdown deadlines. Keep their short bounds, but
  # do not race unrelated codec load and replay work in the async suite.
  use ExUnit.Case, async: false

  @lifecycle_timeout 5_000
  alias Parlora.{Event, SessionSupervisor}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, OrderPolicy}

  defmodule Leaf do
    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    @impl true
    def init(observer) do
      Process.flag(:trap_exit, true)
      send(observer, {:shutdown_leaf, self()})
      {:ok, nil}
    end
  end

  defmodule StalledPolicy do
    def interpret(_snapshot, _trigger, options) do
      Process.flag(:trap_exit, true)
      {:ok, _leaf} = Leaf.start_link(options[:observer])
      send(options[:observer], {:shutdown_policy, self()})
      receive do: (:release -> {:ok, []})
    end
  end

  defmodule Adapter do
    use GenServer

    def start_link(init, options) do
      Process.put(:shutdown_audit, options)
      GenServer.start_link(__MODULE__, {init, options})
    end

    def close(pid, id, reason) do
      options = Process.get(:shutdown_audit)
      send(options[:observer], {:shutdown_callback, options[:role], self(), reason})

      case options[:mode] do
        :callback ->
          {:ok, _leaf} = Leaf.start_link(options[:observer])
          receive do: (:release -> :ok)

        :raise ->
          raise "shutdown-private-marker"

        :throw ->
          throw("shutdown-private-marker")

        :exit ->
          exit("shutdown-private-marker")

        _normal ->
          GenServer.call(pid, {:close, id, reason}, :infinity)
      end
    end

    def read_audio(pid, budget) do
      case GenServer.call(pid, {:read, budget}, :infinity) do
        {:stall_pipeline, observer} ->
          {:ok, _leaf} = Leaf.start_link(observer)
          send(observer, {:shutdown_pipeline, self()})
          receive do: (:release -> {:ok, []})

        reply ->
          reply
      end
    end

    defdelegate write_audio(pid, frame), to: MemoryAudio
    defdelegate control(pid, id, control), to: MemoryAudio
    defdelegate append_context(pid, update), to: MemoryAudio
    defdelegate submit(pid, request), to: FakeBackend
    defdelegate cancel(pid, id, request_id, reason), to: FakeBackend

    @impl true
    def init({init, options}) do
      Process.flag(:trap_exit, true)

      {:ok, state} =
        if options[:role] == :backend,
          do: FakeBackend.init({init, options}),
          else: MemoryAudio.init({init, options[:role], options})

      {:ok, Map.merge(state, %{audit: options, mode: options[:mode], reads: 0})}
    end

    @impl true
    def handle_call({:read, _budget}, _from, %{reads: 1, mode: :pipeline, audit: options} = state) do
      {:reply, {:stall_pipeline, options[:observer]}, %{state | reads: 2}}
    end

    def handle_call({:close, _id, _reason}, _from, %{mode: :server, audit: options} = state) do
      {:ok, _leaf} = Leaf.start_link(options[:observer])
      send(options[:observer], {:shutdown_server, self()})
      receive do: (:release -> {:reply, :ok, state})
    end

    def handle_call({:close, _id, :finish}, _from, %{mode: :finish_work} = state),
      do: {:reply, :ok, state}

    def handle_call({:read, _budget} = call, from, state),
      do: MemoryAudio.handle_call(call, from, %{state | reads: state.reads + 1})

    def handle_call(call, from, %{audit: options} = state) do
      if options[:role] == :backend,
        do: FakeBackend.handle_call(call, from, state),
        else: MemoryAudio.handle_call(call, from, state)
    end

    @impl true
    defdelegate handle_info(message, state), to: MemoryAudio
  end

  for role <- [:channel, :provider, :backend] do
    @role role
    test "#{role} close callback cannot block status or the shutdown deadline" do
      {pid, state} = boot([{@role, :callback}])
      refs = owned_monitors(pid, state)
      started = System.monotonic_time(:millisecond)
      assert :ok = Parlora.close(pid)
      assert_receive {:shutdown_callback, @role, owner, reason}
      assert reason == if(@role == :backend, do: :cancel, else: :session_closed)
      assert owner == state.startup.owners[@role].owner
      assert Parlora.status(pid).status == :closing
      assert_receive {:shutdown_leaf, leaf}
      leaf_ref = Process.monitor(leaf)
      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 700
      assert System.monotonic_time(:millisecond) - started < 700
      assert_down([leaf_ref | refs])
    end
  end

  test "all close callbacks run independently and repeated close cannot extend the deadline" do
    {pid, state} = boot(channel: :callback, provider: :callback, backend: :callback)
    refs = owned_monitors(pid, state)
    started = System.monotonic_time(:millisecond)
    assert :ok = Parlora.close(pid, :finish)
    timer = :sys.get_state(pid).shutdown_timer

    for role <- [:channel, :provider, :backend] do
      assert_receive {:shutdown_callback, ^role, _owner, reason}
      assert reason == if(role == :backend, do: :finish, else: :session_closed)
    end

    leaves =
      for _ <- 1..3 do
        assert_receive {:shutdown_leaf, leaf}
        Process.monitor(leaf)
      end

    Process.sleep(100)
    assert :ok = Parlora.close(pid, :cancel)
    assert :sys.get_state(pid).shutdown_timer == timer
    assert Parlora.status(pid).status == :closing
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 600
    assert System.monotonic_time(:millisecond) - started < 700
    assert_down(leaves ++ refs)
    refute_received {:shutdown_callback, _role, _owner, _reason}
  end

  test "a stalled adapter server and its exit-trapping descendants are forced down" do
    {pid, state} = boot(backend: :server)
    refs = owned_monitors(pid, state)
    assert :ok = Parlora.close(pid)
    assert_receive {:shutdown_server, backend}
    assert backend == elem(state.adapters.backend, 1)
    assert_receive {:shutdown_leaf, leaf}
    leaf_ref = Process.monitor(leaf)
    assert Parlora.status(pid).status == :closing
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 700
    assert_down([leaf_ref | refs])
  end

  test "a stalled pipeline callback and its descendants cannot block teardown" do
    {pid, state} = boot(channel: :pipeline)
    assert_receive {:shutdown_pipeline, pipeline}
    assert pipeline == state.input_pipeline
    assert_receive {:shutdown_leaf, leaf}
    refs = [Process.monitor(leaf) | owned_monitors(pid, state)]
    assert :ok = Parlora.close(pid)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 700
    assert_down(refs)
  end

  test "coordinator death during a stalled close cleans owners, adapters and callback children" do
    {pid, state} = boot(backend: :callback)
    refs = owned_monitors(pid, state)
    assert :ok = Parlora.close(pid)
    assert_receive {:shutdown_callback, :backend, _owner, :cancel}
    assert_receive {:shutdown_leaf, leaf}
    leaf_ref = Process.monitor(leaf)
    Process.exit(pid, :kill)
    assert_down([leaf_ref | refs])
  end

  test "the adapter deadline is enforced even while the closing coordinator is suspended" do
    {pid, state} = boot(backend: :callback)
    refs = owned_monitors(pid, state)
    assert :ok = Parlora.close(pid)
    assert_receive {:shutdown_callback, :backend, owner, :cancel}
    assert_receive {:shutdown_leaf, leaf}
    backend = elem(state.adapters.backend, 1)
    adapter_refs = Enum.map([owner, backend, leaf], &Process.monitor/1)
    :ok = :sys.suspend(pid)
    assert_down(adapter_refs)
    assert Process.alive?(pid)
    :ok = :sys.resume(pid)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 700
    assert_down(refs)
  end

  test "session exit is independent of an adapter whose cleanup has not been scheduled" do
    {pid, state} = boot([])
    refs = owned_monitors(pid, state)
    session_ref = Process.monitor(pid)
    provider = elem(state.adapters.provider, 1)
    owner = state.startup.owners.provider.owner
    watcher = state.startup.owners.provider.watcher

    for process <- [owner, watcher], do: :erlang.suspend_process(process)

    try do
      assert :ok = Parlora.close(pid)
      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 700
      assert_receive {:DOWN, ^session_ref, :process, ^pid, _reason}
      assert Process.alive?(provider)
    after
      for process <- [owner, watcher] do
        try do
          :erlang.resume_process(process)
        rescue
          ArgumentError -> :ok
        end
      end
    end

    assert_down(refs)
  end

  test "close exceptions remain private and cannot prevent other adapters from closing" do
    for mode <- [:raise, :throw, :exit] do
      {pid, state} = boot(backend: mode)
      refs = owned_monitors(pid, state)
      assert :ok = Parlora.close(pid)
      assert_receive {:shutdown_callback, :backend, _owner, :cancel}
      assert_receive {:parlora_event, %Event{source: :channel, type: :closed}}
      assert_receive {:parlora_event, %Event{source: :provider, type: :closed}}
      assert_receive {:parlora_event, %Event{source: :session, type: :closed} = event}, 700
      refute inspect(event) =~ "shutdown-private-marker"
      assert_down(refs)
    end
  end

  test "finish preserves backend completion and provider finalization during shutdown" do
    {pid, state} = boot(backend: :finish_work)
    refs = owned_monitors(pid, state)
    request = request(state)
    assert :ok = Parlora.close(pid, :finish)
    assert_receive {:shutdown_callback, :backend, _owner, :finish}
    assert Parlora.status(pid).status == :closing
    backend = elem(state.adapters.backend, 1)
    assert :ok = FakeBackend.complete(backend, request, "Verified completion")
    assert :ok = FakeBackend.inject(backend, :closed, %{}, [])

    assert_receive {:parlora_event, %Event{source: :session, type: :closed, payload: payload}},
                   700

    assert payload.jobs[request.id] == :completed
    assert payload.finalized?
    assert_down(refs)
  end

  test "a forced close reports outstanding work as uncertain instead of confirming cancellation" do
    {pid, state} = boot(backend: :callback)
    refs = owned_monitors(pid, state)
    request = request(state)
    assert :ok = Parlora.close(pid)
    assert_receive {:shutdown_leaf, leaf}
    leaf_ref = Process.monitor(leaf)

    assert_receive {:parlora_event, %Event{source: :session, type: :closed, payload: payload}},
                   700

    assert payload.jobs[request.id] == :uncertain
    assert_down([leaf_ref | refs])
    refute_received {:parlora_event, %Event{source: :backend, type: :request_cancelled}}
  end

  test "a stalled policy and its exit-trapping descendants cannot delay shutdown" do
    {pid, state} = boot([], context_policy: {StalledPolicy, observer: self()})
    refs = owned_monitors(pid, state)
    assert :ok = Parlora.update_context(pid, %{order: "123"})
    assert_receive {:shutdown_policy, worker}
    assert_receive {:shutdown_leaf, leaf}
    work_refs = Enum.map([worker, leaf], &Process.monitor/1)
    assert :ok = Parlora.close(pid)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 700
    assert_down(work_refs ++ refs)
  end

  defp request(state) do
    provider = elem(state.adapters.provider, 1)
    :ok = MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: "order 123"})
    :ok = MemoryAudio.inject(provider, :delegation_requested, %{id: "call", offset_ms: 0})
    assert_receive {:submitted, request}, 1_000
    request
  end

  defp boot(modes, overrides \\ []) do
    options =
      for role <- [:channel, :provider, :backend] do
        {role, {Adapter, observer: self(), role: role, mode: modes[role]}}
      end

    {:ok, pid} =
      Parlora.start_session(
        options ++
          Keyword.merge(
            [
              context_policy: {OrderPolicy, []},
              event_sink: self(),
              limits: [startup_timeout_ms: 2_000, shutdown_timeout_ms: 300]
            ],
            overrides
          )
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, @lifecycle_timeout
    {pid, :sys.get_state(pid)}
  end

  defp owned_monitors(pid, state) do
    adapters = Enum.map(state.adapters, fn {_role, {_module, pid}} -> pid end)
    owners = Enum.flat_map(state.startup.owners, fn {_role, o} -> [o.owner, o.watcher] end)
    supervisor = GenServer.whereis(SessionSupervisor.via(state.id, :adapters))

    Enum.map(
      [pid, supervisor, state.input_pipeline, state.output_pipeline | adapters ++ owners],
      &Process.monitor/1
    )
  end

  defp assert_down(refs) do
    Enum.each(refs, fn ref ->
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, @lifecycle_timeout
    end)
  end
end
