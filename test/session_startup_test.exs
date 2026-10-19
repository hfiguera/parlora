defmodule Parlora.SessionStartupTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, Event, SessionSupervisor}
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, MemoryProvider, OrderPolicy}

  defmodule StalledLeaf do
    use GenServer
    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    @impl true
    def init(observer) do
      Process.flag(:trap_exit, true)
      send(observer, {:startup_leaf, self()})

      receive do
        :release -> {:ok, nil}
      end
    end
  end

  defmodule StalledAdapter do
    use GenServer

    def start_link(init, options) do
      send(options[:observer], {:startup_owner, self()})

      if options[:phase] == :before_child do
        receive do
          :release -> :ok
        end
      end

      case options[:phase] do
        :raise -> raise "startup-private-marker"
        :throw -> throw("startup-private-marker")
        :exit -> exit("startup-private-marker")
        :invalid -> {:ok, :not_a_pid}
        :ignore -> :ignore
        _other -> GenServer.start_link(__MODULE__, {init, options})
      end
    end

    @impl true
    def init({init, options}) do
      Process.flag(:trap_exit, true)
      send(options[:observer], {:startup_child, self()})

      case options[:phase] do
        :init ->
          receive do
            :release -> :ok
          end

        :nested ->
          StalledLeaf.start_link(options[:observer])

        :named_nested ->
          Supervisor.start_link(Parlora.SessionStartupTest.StalledTree, options[:observer],
            name: Parlora.SessionStartupTest.StalledTree
          )

        _other ->
          :ok
      end

      if options[:phase] == :readiness do
        {:ok, state} =
          MemoryAudio.init({init, options[:role], Keyword.put(options, :delay_ready, true)})

        {:ok, state, {:continue, :blocked_readiness}}
      else
        {:ok, state} = MemoryAudio.init({init, options[:role], options})
        {:ok, Map.put(state, :stall_read, options[:phase] == :capture_read)}
      end
    end

    @impl true
    def handle_continue(:blocked_readiness, state) do
      send(state.options[:observer], {:startup_readiness, self()})

      receive do
        :release -> {:noreply, state}
      end
    end

    @impl true
    def handle_call({:read, _budget} = call, from, %{stall_read: true} = state) do
      send(state.options[:observer], {:startup_capture_read, self()})

      receive do
        :release -> MemoryAudio.handle_call(call, from, %{state | stall_read: false})
      end
    end

    defdelegate handle_call(call, from, state), to: MemoryAudio
    @impl true
    defdelegate handle_info(message, state), to: MemoryAudio

    defdelegate close(pid, id, reason), to: MemoryAudio
    defdelegate read_audio(pid, budget), to: MemoryAudio
    defdelegate write_audio(pid, frame), to: MemoryAudio
    defdelegate control(pid, id, control), to: MemoryAudio
  end

  defmodule StalledTree do
    use Supervisor

    @impl true
    def init(observer) do
      send(observer, {:startup_tree, self()})
      Supervisor.init([{StalledLeaf, observer}], strategy: :one_for_one)
    end
  end

  for {role, phase} <- [channel: :before_child, provider: :init, backend: :nested] do
    @role role
    @phase phase
    test "deadline cleans #{@role} stalled #{@phase}, including earlier adapters" do
      pid = boot(@role, @phase, startup_timeout_ms: 300, shutdown_timeout_ms: 100)
      assert_receive {:startup_owner, owner}
      state = :sys.get_state(pid)
      assert state.startup.pending.owner == owner
      children = stalled_children(@phase)
      prior = Enum.map(state.adapters, fn {_role, {_module, adapter}} -> adapter end)
      refs = monitors([pid, owner, state.startup.pending.watcher | children ++ prior])

      assert_receive {:parlora_event,
                      %Event{
                        source: :session,
                        type: :failed,
                        payload: %{error: %{code: :timeout}}
                      }},
                     5_000

      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 5_000
      assert_down(refs)
      refute_received {:parlora_event, %Event{source: :session, type: :ready}}
    end
  end

  test "close stays responsive during init and prevents late readiness or further startup" do
    pid = boot(:provider, :init, startup_timeout_ms: 2_000, shutdown_timeout_ms: 100)
    assert_receive {:startup_owner, owner}
    assert_receive {:startup_child, child}
    state = :sys.get_state(pid)
    refs = monitors([pid, owner, child, state.startup.pending.watcher])
    assert Parlora.status(pid).status == :starting
    assert :ok = Parlora.close(pid)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    assert_down(refs)
    send(child, :release)
    refute_received {:adapter, :backend, _backend}
    refute_received {:parlora_event, %Event{source: :session, type: :ready}}
  end

  test "coordinator death cleans a pending init even when it traps exits" do
    pid = boot(:channel, :nested, startup_timeout_ms: 2_000)
    assert_receive {:startup_owner, owner}
    assert_receive {:startup_child, child}
    assert_receive {:startup_leaf, leaf}
    watcher = :sys.get_state(pid).startup.pending.watcher
    refs = monitors([pid, owner, watcher, child, leaf])
    Process.exit(pid, :kill)
    assert_down(refs)
  end

  test "startup cleanup reaches a child blocked under a named OTP supervisor" do
    pid = boot(:channel, :named_nested, startup_timeout_ms: 300, shutdown_timeout_ms: 100)
    assert_receive {:startup_owner, owner}
    assert_receive {:startup_child, child}
    assert_receive {:startup_tree, tree}
    assert_receive {:startup_leaf, leaf}
    refs = monitors([pid, owner, child, tree, leaf])
    assert_receive {:parlora_event, %Event{source: :session, type: :failed}}
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    assert_down(refs)
    assert Process.whereis(StalledTree) == nil
  end

  test "startup exceptions and malformed returns close partial sessions without exposing details" do
    for phase <- [:raise, :throw, :exit, :invalid, :ignore] do
      pid = boot(:provider, phase, startup_timeout_ms: 2_000)
      assert_receive {:adapter, :channel, channel}
      assert_receive {:startup_owner, owner}
      refs = monitors([pid, channel, owner])

      assert_receive {:parlora_event,
                      %Event{
                        source: :session,
                        type: :failed,
                        payload: %{error: %{code: :adapter_failed}}
                      } = event}

      refute inspect(event) =~ "startup-private-marker"
      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
      assert_down(refs)
      refute_received {:adapter, :backend, _backend}
    end
  end

  test "readiness stalls cannot block timeout cleanup through adapter close callbacks" do
    pid = boot(:channel, :readiness, startup_timeout_ms: 300, shutdown_timeout_ms: 100)
    assert_receive {:startup_readiness, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    eventually(fn -> :sys.get_state(pid).startup.pending == nil end)
    refs = monitors([pid, channel, provider, backend])
    assert Parlora.status(pid).status == :starting

    assert_receive {:parlora_event,
                    %Event{source: :session, type: :failed, payload: %{error: %{code: :timeout}}}},
                   5_000

    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}, 5_000
    assert_down(refs)
    refute_received {:parlora_event, %Event{source: :session, type: :ready}}
  end

  test "the initial capture drain cannot block startup timeout or publish premature readiness" do
    pid = boot(:channel, :capture_read, startup_timeout_ms: 300, shutdown_timeout_ms: 100)
    assert_receive {:startup_capture_read, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    state = :sys.get_state(pid)
    assert is_pid(state.input_pipeline)
    assert Parlora.status(pid).status == :starting

    refs =
      monitors([pid, channel, provider, backend, state.input_pipeline, state.output_pipeline])

    assert_receive {:parlora_event,
                    %Event{source: :session, type: :failed, payload: %{error: %{code: :timeout}}}}

    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    assert_down(refs)
    refute_received {:parlora_event, %Event{source: :session, type: :ready}}
  end

  test "completing the initial capture drain admits readiness and preserves fresh audio" do
    pid = boot(:channel, :capture_read, startup_timeout_ms: 2_000, shutdown_timeout_ms: 100)
    assert_receive {:startup_capture_read, channel}
    assert_receive {:adapter, :provider, provider}
    assert Parlora.status(pid).status == :starting
    refute_received {:parlora_event, %Event{source: :session, type: :ready}}
    send(channel, :release)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    frame = AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "fresh", 0)
    assert :ok = MemoryAudio.audio(channel, frame)
    eventually(fn -> :sys.get_state(provider).outbound.bytes == 480 end)
    assert [^frame] = MemoryAudio.drain(provider)
  end

  test "successful early ready events wait for all starts and preserve trapped-exit adapters" do
    pid = boot(:channel, :init, startup_timeout_ms: 2_000, shutdown_timeout_ms: 100)
    assert_receive {:startup_owner, owner}
    assert_receive {:startup_child, channel}
    send(channel, :release)
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    assert Process.alive?(owner) and Process.alive?(channel)
    frame = AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "fresh", 0)
    assert :ok = MemoryAudio.audio(channel, frame)
    eventually(fn -> :sys.get_state(provider).outbound.bytes == 480 end)
    assert [^frame] = MemoryAudio.drain(provider)

    state = :sys.get_state(pid)
    supervisor = GenServer.whereis(SessionSupervisor.via(state.id, :adapters))
    owners = Enum.map(DynamicSupervisor.which_children(supervisor), &elem(&1, 1))
    refs = monitors([pid, channel, provider, backend | owners])
    assert :ok = Parlora.close(pid)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    assert_down(refs)
  end

  defp boot(role, phase, limits) do
    defaults = [
      channel: {MemoryChannel, observer: self()},
      provider: {MemoryProvider, observer: self()},
      backend: {FakeBackend, observer: self()},
      context_policy: {OrderPolicy, []},
      event_sink: self(),
      limits: limits
    ]

    options =
      Keyword.put(defaults, role, {StalledAdapter, observer: self(), role: role, phase: phase})

    {:ok, pid} = Parlora.start_session(options)
    on_exit(fn -> if Process.alive?(pid), do: Parlora.close(pid) end)
    pid
  end

  defp stalled_children(:before_child), do: []

  defp stalled_children(:init) do
    assert_receive {:startup_child, child}
    [child]
  end

  defp stalled_children(:nested) do
    assert_receive {:startup_child, child}
    assert_receive {:startup_leaf, leaf}
    [child, leaf]
  end

  defp monitors(pids), do: Enum.map(pids, &Process.monitor/1)

  defp assert_down(refs) do
    Enum.each(refs, fn ref -> assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000 end)
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
