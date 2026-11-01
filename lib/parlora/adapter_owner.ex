defmodule Parlora.AdapterOwner do
  @moduledoc false
  use GenServer
  alias Parlora.{Error, ProcessTree}

  # A supervisor must never run application startup code in its own process.
  # Acknowledge this owner first; the adapter remains its linked OTP child.
  def start_link(startup) do
    reference = make_ref()

    case GenServer.start_link(__MODULE__, {startup, self(), reference}) do
      {:ok, pid} ->
        receive do
          {:adapter_watcher, ^reference, watcher} -> {:ok, pid, watcher}
        end

      error ->
        error
    end
  end

  def cancel(watcher), do: send(watcher, :cancel)

  def close(watcher, id, reason, deadline),
    do: send(watcher, {:close, id, reason, deadline})

  def execute(owner, reference, callback, deadline),
    do: send(owner, {:execute, reference, callback, deadline})

  # Pipeline callbacks can also be inside application code. Cleanup must never
  # wait in the coordinator or in the shared adapter supervisor.
  def stop(pid, notify) when is_pid(pid) do
    spawn(fn ->
      abort_tree(pid)
      if is_pid(notify), do: send(notify, {:parlora_process_stopped, self()})
    end)
  end

  def stop(nil, _notify), do: nil

  @impl true
  def init({startup, caller, reference}) do
    Process.flag(:trap_exit, true)
    {module, init, options, deadline} = startup.()
    timeout = max(0, div(deadline - System.monotonic_time(:microsecond) + 999, 1_000))
    owner = self()
    {watcher, monitor} = spawn_monitor(fn -> watch(owner, init.event_sink, timeout) end)

    receive do
      {:adapter_tree_ready, ^watcher} -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, ^watcher, _reason} -> exit(:adapter_watcher_failed)
    end

    send(caller, {:adapter_watcher, reference, watcher})

    {:ok,
     %{
       module: module,
       init: init,
       options: options,
       watcher: watcher,
       adapter: nil,
       deadline: deadline
     }, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    case start_adapter(state) do
      {:ok, pid} ->
        Process.monitor(pid)
        send(state.watcher, {:started, self(), pid})
        send(state.init.event_sink, {:parlora_adapter_started, self(), pid})
        {:noreply, %{state | adapter: pid, options: []}}

      {:error, reason} ->
        send(state.init.event_sink, {:parlora_adapter_failed, self(), reason})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{adapter: pid} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, _reference, :process, pid, _reason}, %{adapter: pid} = state),
    do: {:stop, :normal, state}

  def handle_info({:close, id, reason, deadline}, state) do
    if System.monotonic_time(:microsecond) < deadline, do: close_adapter(state, id, reason)
    {:noreply, state}
  end

  def handle_info({:execute, reference, callback, deadline}, state) do
    reply =
      if System.monotonic_time(:microsecond) < deadline,
        do: invoke(callback),
        else:
          Error.tuple(:timeout, "Command expired before adapter invocation", %{
            execution: :never_submitted
          })

    send(state.init.event_sink, {:parlora_command_result, reference, reply})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl true
  def terminate(_reason, _state), do: stop_children(self())

  # Freeze the starter before inspecting its children: otherwise a late spawn
  # could escape between the inspection and termination. Kill OTP descendants
  # explicitly, including init callbacks that trap exits. Never follow links to
  # shared services or the supervising parent.
  defp abort(pid) do
    :erlang.suspend_process(pid)
    reference = Process.monitor(pid)

    try do
      stop_children(pid)
    after
      Process.exit(pid, :kill)
    end

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    end
  rescue
    ArgumentError -> :ok
  catch
    :error, :exited -> :ok
  end

  defp abort_tree(pid) do
    :erlang.suspend_process(pid)

    case ProcessTree.lookup(pid) do
      nil -> :ok
      tree -> ProcessTree.stop(tree, pid)
    end

    abort(pid)
  rescue
    ArgumentError -> :ok
  catch
    :error, :exited -> :ok
  end

  defp invoke(callback) do
    case callback.() do
      :ok ->
        :ok

      {:error, %Error{}} = error ->
        error

      _other ->
        Error.tuple(:adapter_failed, "Invalid adapter admission reply", %{outcome: :unknown})
    end
  rescue
    _exception -> Error.tuple(:adapter_failed, "Adapter command failed", %{outcome: :unknown})
  catch
    _kind, _reason -> Error.tuple(:adapter_failed, "Adapter command exited", %{outcome: :unknown})
  end

  defp stop_children(parent) do
    case Process.info(parent, :links) do
      {:links, links} ->
        Enum.each(links, &stop_child(&1, parent))

      nil ->
        :ok
    end
  end

  defp stop_child(pid, parent) when is_pid(pid) and node(pid) == node() do
    if child?(pid, parent), do: abort(pid)
  end

  defp stop_child(_link, _parent), do: :ok

  defp child?(pid, parent) do
    case :erlang.process_info(pid, {:dictionary, :"$ancestors"}) do
      {{:dictionary, :"$ancestors"}, [^parent | _ancestors]} ->
        true

      {{:dictionary, :"$ancestors"}, [name | _ancestors]} when is_atom(name) ->
        Process.info(parent, :registered_name) == {:registered_name, name}

      _other ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp start_adapter(state) do
    if System.monotonic_time(:microsecond) < state.deadline do
      case state.module.start_link(state.init, state.options) do
        {:ok, pid} when is_pid(pid) -> {:ok, pid}
        _other -> {:error, :adapter_failed}
      end
    else
      {:error, :timeout}
    end
  rescue
    _exception -> {:error, :adapter_failed}
  catch
    _kind, _reason -> {:error, :adapter_failed}
  end

  defp watch(owner, session, timeout) do
    tree = ProcessTree.register(owner)
    owner_ref = Process.monitor(owner)
    session_ref = Process.monitor(session)
    send(owner, {:adapter_tree_ready, self()})

    receive do
      {:started, ^owner, _adapter} -> watch_running(owner, owner_ref, session_ref, tree)
      :cancel -> ProcessTree.stop(tree)
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> ProcessTree.stop(tree)
      {:DOWN, ^session_ref, :process, ^session, _reason} -> ProcessTree.stop(tree)
    after
      timeout ->
        send(session, {:parlora_adapter_failed, owner, :timeout})
        ProcessTree.stop(tree)
    end
  end

  defp watch_running(owner, owner_ref, session_ref, tree) do
    receive do
      {:close, id, reason, deadline} ->
        send(owner, {:close, id, reason, deadline})
        watch_closing(owner, owner_ref, session_ref, deadline, tree)

      :cancel ->
        ProcessTree.stop(tree)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        ProcessTree.stop(tree)

      {:DOWN, ^session_ref, :process, _session, _reason} ->
        ProcessTree.stop(tree)
    end
  end

  defp watch_closing(owner, owner_ref, session_ref, deadline, tree) do
    timeout = max(0, div(deadline - System.monotonic_time(:microsecond) + 999, 1_000))

    receive do
      :cancel -> ProcessTree.stop(tree)
      {:DOWN, ^owner_ref, :process, ^owner, _reason} -> ProcessTree.stop(tree)
      {:DOWN, ^session_ref, :process, _session, _reason} -> ProcessTree.stop(tree)
    after
      timeout -> ProcessTree.stop(tree)
    end
  end

  defp close_adapter(state, id, reason) do
    state.module.close(state.adapter, id, reason)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
