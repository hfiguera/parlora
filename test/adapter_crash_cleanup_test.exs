defmodule Parlora.AdapterCrashCleanupTest do
  use ExUnit.Case, async: true

  # Orphan discovery sweeps run asynchronously across the VM. Allow scheduling
  # headroom for observing cleanup; session shutdown deadlines have separate tests.
  @lifecycle_timeout 5_000
  alias Parlora.{Event, SessionSupervisor}
  alias Parlora.TestSupport.{FakeBackend, MemoryChannel, MemoryProvider, OrderPolicy}

  defmodule Leaf do
    use GenServer
    def start_link(options), do: GenServer.start_link(__MODULE__, options)
    @impl true
    def init(options) do
      Process.flag(:trap_exit, true)
      send(self(), :block)
      {:ok, options}
    end

    @impl true
    def handle_info(:block, options) do
      if options[:nested], do: Leaf.start_link(Keyword.put(options, :nested, false))
      send(options[:observer], {:orphan_candidate, self()})
      receive do: (:release -> {:noreply, options})
    end
  end

  defmodule Backend do
    use GenServer
    def start_link(init, options), do: GenServer.start_link(__MODULE__, {init, options})
    @impl true
    def init({init, options}) do
      {:ok, _leaf} = Leaf.start_link(options)
      FakeBackend.init({init, options})
    end

    @impl true
    defdelegate handle_call(message, from, state), to: FakeBackend
    defdelegate submit(pid, request), to: FakeBackend
    defdelegate cancel(pid, id, request, reason), to: FakeBackend
    defdelegate close(pid, id, reason), to: FakeBackend
  end

  for victim <- [:adapter, :owner] do
    @victim victim
    test "#{victim} crash cannot orphan a blocked exit-trapping OTP subtree" do
      {:ok, session} =
        Parlora.start_session(
          channel: {MemoryChannel, []},
          provider: {MemoryProvider, []},
          backend: {Backend, observer: self(), nested: true},
          context_policy: {OrderPolicy, []},
          event_sink: self(),
          limits: [startup_timeout_ms: 2_000, shutdown_timeout_ms: 100]
        )

      on_exit(fn -> if Process.alive?(session), do: Process.exit(session, :kill) end)
      assert_receive {:parlora_event, %Event{source: :session, type: :ready}}, @lifecycle_timeout
      state = :sys.get_state(session)
      assert_receive {:orphan_candidate, first}, @lifecycle_timeout
      assert_receive {:orphan_candidate, second}, @lifecycle_timeout
      {:ok, unrelated} = Leaf.start_link(observer: self())
      assert_receive {:orphan_candidate, ^unrelated}, @lifecycle_timeout
      on_exit(fn -> Process.exit(unrelated, :kill) end)
      supervisor = GenServer.whereis(SessionSupervisor.via(state.id, :adapters))
      owner = state.startup.owners.backend.owner
      adapter = elem(state.adapters.backend, 1)
      victim = if @victim == :owner, do: owner, else: adapter

      owned = [
        session: session,
        supervisor: supervisor,
        owner: owner,
        adapter: adapter,
        leaf: first,
        nested_leaf: second,
        watcher: state.startup.owners.backend.watcher
      ]

      on_exit(fn -> Enum.each(owned, fn {_role, pid} -> Process.exit(pid, :kill) end) end)
      monitors = for {role, pid} <- owned, do: {role, pid, Process.monitor(pid)}
      deadline = System.monotonic_time(:millisecond) + @lifecycle_timeout
      Process.exit(victim, :kill)

      for {role, pid, ref} <- monitors do
        remaining = max(0, deadline - System.monotonic_time(:millisecond))

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason},
                       remaining,
                       "Crash cleanup timed out waiting for #{role} #{inspect(pid)}"
      end

      assert Process.alive?(unrelated)
    end
  end
end
