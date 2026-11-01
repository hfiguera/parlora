defmodule Parlora.ProcessTree do
  @moduledoc false
  use GenServer

  @key :"$parlora_process_tree"

  @type node_data :: %{
          parent: pid() | nil,
          children: %{pid() => true},
          born?: boolean(),
          dead?: boolean()
        }

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def register(root, options \\ []) when is_pid(root) and node(root) == node() do
    GenServer.call(__MODULE__, {:register, root, Keyword.get(options, :tasks, false)})
  end

  def track(tree \\ nil) do
    tree = tree || register(self())
    Process.put(@key, tree)
    tree
  end

  def lookup(pid) do
    case :erlang.process_info(pid, {:dictionary, @key}) do
      {{:dictionary, @key}, tree} when is_pid(tree) -> tree
      _other -> nil
    end
  end

  def stop(tree, root \\ nil) do
    GenServer.call(__MODULE__, {:stop, tree, root || tree}, :infinity)
  catch
    :exit, {:noproc, _call} -> :ok
    :exit, {:normal, _call} -> :ok
  end

  @impl true
  def init(_options) do
    Process.flag(:trap_exit, true)
    session = :trace.session_create(:parlora_process_tree, self(), [])
    {:ok, %{session: session, nodes: %{}, roots: %{}, jobs: %{}, workers: %{}}}
  end

  @impl true
  def handle_call({:register, root, tasks?}, _from, state) do
    if Map.has_key?(state.roots, root) do
      {:reply, root, state}
    else
      traced? =
        case :trace.info(state.session, root, :flags) do
          {:flags, flags} -> :procs in flags
          _gone -> false
        end

      node = Map.get(state.nodes, root, %{new_node() | born?: not traced?})
      monitor = Process.monitor(root)
      :trace.process(state.session, root, true, [:procs, :set_on_spawn])
      roots = Map.put(state.roots, root, %{monitor: monitor, tasks?: tasks?})
      {:reply, root, %{state | roots: roots, nodes: Map.put(state.nodes, root, node)}}
    end
  end

  def handle_call({:stop, tree, root}, from, state) do
    if Map.has_key?(state.roots, tree) or Map.has_key?(state.nodes, root),
      do: {:noreply, request_cleanup(state, root, from)},
      else: {:reply, :ok, state}
  end

  def handle_call({:snapshot, root}, _from, state),
    do: {:reply, descendants(state.nodes, [root], %{}), state}

  @impl true
  def handle_info({:trace, parent, :spawn, child, _entry}, state) when node(child) == node() do
    {:noreply, record_spawn(state, parent, child)}
  end

  def handle_info({:trace, pid, :exit, _reason}, state),
    do: {:noreply, record_exit(state, pid)}

  def handle_info({:reap_task, pid}, state) do
    case state.nodes[pid] do
      %{dead?: true} -> {:noreply, request_cleanup(state, pid, nil)}
      _gone -> {:noreply, state}
    end
  end

  def handle_info({:cleanup_done, root, worker, owned}, state) do
    case state.jobs[root] do
      %{worker: ^worker} = job ->
        Process.demonitor(job.monitor, [:flush])
        state = Enum.reduce(owned, state, fn {pid, _owned}, acc -> unregister(acc, pid) end)
        Enum.each(job.callers, &GenServer.reply(&1, :ok))

        {:noreply,
         %{
           state
           | jobs: Map.delete(state.jobs, root),
             workers: Map.delete(state.workers, job.monitor)
         }}

      _obsolete ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case state.roots[pid] do
      %{monitor: ^monitor} ->
        {:noreply, request_cleanup(state, pid, nil)}

      _other ->
        if Map.has_key?(state.workers, monitor),
          do: {:stop, :cleanup_failed, state},
          else: {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl true
  def terminate(_reason, state) do
    # A trace session's destruction invokes the VM-wide trace cleaner. Keep this
    # session for the application's lifetime, rather than destroying one per call.
    owned = Map.new(state.nodes, fn {pid, _node} -> {pid, true} end)
    pending = Map.new(owned, fn {pid, _owned} -> {freeze_and_flush(state.session, pid), pid} end)
    {_state, owned} = settle(state, owned, pending)
    kill_owned(owned)
    Enum.each(state.jobs, fn {_root, job} -> Process.exit(job.worker, :kill) end)
    :trace.session_destroy(state.session)
  end

  defp record_spawn(state, parent, child) do
    parent_node = Map.get(state.nodes, parent, new_node())
    child_node = Map.get(state.nodes, child, new_node())

    nodes =
      state.nodes
      |> Map.put(parent, %{parent_node | children: Map.put(parent_node.children, child, true)})
      |> Map.put(child, %{child_node | parent: parent, born?: true})

    state |> Map.put(:nodes, nodes) |> prune(child) |> schedule_reap(child)
  end

  defp record_exit(state, pid) do
    node = Map.get(state.nodes, pid, new_node())
    state = %{state | nodes: Map.put(state.nodes, pid, %{node | dead?: true})}
    state |> prune(pid) |> schedule_reap(pid)
  end

  # Keep a dead placeholder until its parent's spawn event arrives. Otherwise
  # out-of-order delivery could resurrect dead history or hide live descendants.
  defp prune(state, pid) do
    case state.nodes[pid] do
      %{born?: true, dead?: true, parent: parent, children: children} ->
        if map_size(children) == 0 and not Map.has_key?(state.roots, pid) do
          detach(%{state | nodes: Map.delete(state.nodes, pid)}, parent, pid)
        else
          state
        end

      _alive_or_pending ->
        state
    end
  end

  defp detach(state, nil, _pid), do: state

  defp detach(state, parent, pid) do
    nodes = Map.update!(state.nodes, parent, &%{&1 | children: Map.delete(&1.children, pid)})
    prune(%{state | nodes: nodes}, parent)
  end

  defp schedule_reap(state, pid) do
    parent =
      case state.nodes[pid] do
        nil -> nil
        node -> node.parent
      end

    if match?(%{tasks?: true}, state.roots[parent]) and
         match?(%{dead?: true}, state.nodes[pid]),
       do: send(self(), {:reap_task, pid})

    state
  end

  defp unregister(state, pid) do
    case Map.pop(state.roots, pid) do
      {nil, _roots} ->
        state

      {root, roots} ->
        Process.demonitor(root.monitor, [:flush])
        prune(%{state | roots: roots}, pid)
    end
  end

  defp new_node,
    do: %{parent: nil, children: %{}, born?: false, dead?: false}

  defp request_cleanup(state, root, from) do
    case state.jobs[root] do
      nil ->
        manager = self()
        session = state.session
        owned = descendants(state.nodes, [root], %{})
        {worker, monitor} = spawn_monitor(fn -> cleanup_worker(manager, session, root, owned) end)
        job = %{worker: worker, monitor: monitor, callers: List.wrap(from)}

        %{
          state
          | jobs: Map.put(state.jobs, root, job),
            workers: Map.put(state.workers, monitor, root)
        }

      job ->
        job = %{job | callers: job.callers ++ List.wrap(from)}
        %{state | jobs: Map.put(state.jobs, root, job)}
    end
  end

  defp cleanup_worker(manager, session, root, owned) do
    owned = freeze_branch(manager, session, root, owned, owned)
    kill_owned(owned)
    flush_events(session, owned)
    GenServer.call(manager, {:snapshot, root}, :infinity)
    send(manager, {:cleanup_done, root, self(), owned})
  end

  defp freeze_branch(manager, session, root, owned, new) do
    Enum.each(new, fn {pid, _owned} -> freeze(pid) end)
    flush_events(session, new)
    branch = GenServer.call(manager, {:snapshot, root}, :infinity)
    new = Map.reject(branch, fn {pid, _owned} -> Map.has_key?(owned, pid) end)
    owned = Map.merge(owned, new)

    if map_size(new) == 0,
      do: owned,
      else: freeze_branch(manager, session, root, owned, new)
  end

  defp flush_events(session, owned) do
    references = for {pid, _owned} <- owned, do: {pid, :trace.delivered(session, pid)}

    Enum.each(references, fn {pid, reference} ->
      receive do
        {:trace_delivered, ^pid, ^reference} -> :ok
      end
    end)
  end

  defp kill_owned(owned) do
    monitors =
      for {pid, _owned} <- owned do
        reference = Process.monitor(pid)
        Process.exit(pid, :kill)
        {pid, reference}
      end

    Enum.each(monitors, fn {pid, reference} ->
      receive do
        {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
      end
    end)
  end

  @spec descendants(%{pid() => node_data()}, [pid()], %{pid() => true}) :: %{pid() => true}
  defp descendants(_nodes, [], owned), do: owned

  defp descendants(nodes, [pid | rest], owned) do
    if Map.has_key?(owned, pid) do
      descendants(nodes, rest, owned)
    else
      children =
        case nodes[pid] do
          nil -> []
          node -> Map.keys(node.children)
        end

      descendants(nodes, children ++ rest, Map.put(owned, pid, true))
    end
  end

  # Freeze producers, then flush each producer's events before killing anything.
  # Newly discovered branches may already contain grandchildren in the registry.
  @spec settle(map(), %{pid() => true}, %{reference() => pid()}) :: {map(), %{pid() => true}}
  defp settle(state, owned, pending) when map_size(pending) == 0, do: {state, owned}

  defp settle(state, owned, pending) do
    receive do
      {:trace, parent, :spawn, child, _entry} when node(child) == node() ->
        state = record_spawn(state, parent, child)

        {owned, pending} =
          if Map.has_key?(owned, parent) do
            branch = descendants(state.nodes, [child], %{})
            new = Map.reject(branch, fn {pid, _owned} -> Map.has_key?(owned, pid) end)

            more =
              Map.new(new, fn {pid, _owned} -> {freeze_and_flush(state.session, pid), pid} end)

            {Map.merge(owned, new), Map.merge(pending, more)}
          else
            {owned, pending}
          end

        settle(state, owned, pending)

      {:trace, pid, :exit, _reason} ->
        settle(record_exit(state, pid), owned, pending)

      {:trace_delivered, _pid, reference} ->
        settle(state, owned, Map.delete(pending, reference))

      message when is_tuple(message) and elem(message, 0) == :trace ->
        settle(state, owned, pending)
    end
  end

  defp freeze_and_flush(session, pid) do
    freeze(pid)
    :trace.delivered(session, pid)
  end

  defp freeze(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> :ok
  catch
    :error, :exited -> :ok
  end
end
