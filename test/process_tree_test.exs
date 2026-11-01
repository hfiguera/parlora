defmodule Parlora.ProcessTreeTest do
  use ExUnit.Case, async: false
  alias Parlora.{AdapterOwner, ProcessTree}

  setup do
    unless Process.whereis(ProcessTree), do: start_supervised!({ProcessTree, []})
    :ok
  end

  test "a crashed root and intermediate parent cannot hide a surviving descendant" do
    {root, _tree} = tree()
    :sys.suspend(ProcessTree)

    send(
      root,
      {:run,
       fn ->
         observer = self()

         parent =
           spawn(fn ->
             leaf = spawn(fn -> receive do: (:stop -> :ok) end)
             send(observer, {:leaf, leaf})
           end)

         receive do
           {:leaf, leaf} -> send(Process.get(:observer), {:descendants, parent, leaf})
         end
       end}
    )

    assert_receive {:descendants, parent, leaf}
    reference = Process.monitor(leaf)
    Process.exit(root, :kill)
    :sys.resume(ProcessTree)
    assert_receive {:DOWN, ^reference, :process, ^leaf, _reason}
    refute Process.alive?(parent)
  end

  test "cleanup catches descendants still spawning while trace delivery is delayed" do
    observer = self()

    for _ <- 1..20 do
      {root, tree} = tree()
      :sys.suspend(ProcessTree)

      send(
        root,
        {:run,
         fn ->
           spawn(fn ->
             send(observer, :spawning)

             for _ <- 1..100 do
               leaf = spawn(fn -> receive do: (:stop -> :ok) end)
               send(observer, {:spawned, leaf})
             end
           end)
         end}
      )

      assert_receive :spawning
      :sys.resume(ProcessTree)
      assert :ok = ProcessTree.stop(tree)
      refute Process.alive?(root)
      assert_descendants_stopped()
    end
  end

  test "exited descendants are removed while the root remains alive" do
    {root, tree} = tree()
    observer = self()

    send(
      root,
      {:run,
       fn ->
         for _ <- 1..200 do
           {child, reference} = spawn_monitor(fn -> :ok end)
           receive do: ({:DOWN, ^reference, :process, ^child, :normal} -> :ok)
         end

         send(observer, :churn_finished)
       end}
    )

    assert_receive :churn_finished
    eventually(fn -> snapshot(root) == %{root => true} end)
    assert :ok = ProcessTree.stop(tree)
  end

  test "dead parents remain discoverable until their trace exit events arrive" do
    {root, _tree} = tree()
    {child, reference} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^reference, :process, ^child, :normal}

    send(ProcessTree, {:trace, root, :spawn, child, {__MODULE__, :wait, []}})
    assert Map.has_key?(:sys.get_state(ProcessTree).nodes, child)
    send(ProcessTree, {:trace, child, :exit, :normal})
    assert snapshot(root) == %{root => true}

    send(ProcessTree, {:trace, child, :exit, :normal})
    send(ProcessTree, {:trace, root, :spawn, child, {__MODULE__, :wait, []}})
    state = :sys.get_state(ProcessTree)
    refute Map.has_key?(state.nodes, child)
    assert state.nodes[root].children == %{}
  end

  test "an unrelated linked process and another tracer survive cleanup" do
    {root, tree} = tree()
    observer = self()

    shared =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(observer, :shared_ready)
        wait()
      end)

    on_exit(fn -> Process.exit(shared, :kill) end)
    assert_receive :shared_ready
    tracing = :trace.session_create(:process_tree_test, self(), [])
    on_exit(fn -> :trace.session_destroy(tracing) end)
    :trace.process(tracing, shared, true, [:procs])

    send(
      root,
      {:run,
       fn ->
         Process.link(shared)
         send(observer, :linked)
       end}
    )

    assert_receive :linked
    assert :ok = ProcessTree.stop(tree)
    assert Process.alive?(shared)
    assert {:flags, [:procs]} = :trace.info(tracing, shared, :flags)
  end

  test "task results do not wait for descendant cleanup" do
    observer = self()

    root =
      spawn(fn ->
        tree = ProcessTree.track()
        leaf = spawn(fn -> receive do: (:stop -> :ok) end)
        send(observer, {:task_ready, self(), tree, leaf})
        receive do: (:finish -> send(observer, {:result, :done}))
      end)

    assert_receive {:task_ready, ^root, tree, leaf}
    on_exit(fn -> resume_and_stop(tree) end)
    :sys.suspend(ProcessTree)
    reference = Process.monitor(root)
    send(root, :finish)
    assert_receive {:result, :done}
    assert_receive {:DOWN, ^reference, :process, ^root, :normal}
    assert Process.alive?(leaf)
    reference = Process.monitor(leaf)
    :sys.resume(ProcessTree)
    assert_receive {:DOWN, ^reference, :process, ^leaf, :killed}
  end

  test "cancelling a tracked policy waits for the root and its descendants" do
    observer = self()

    root =
      spawn(fn ->
        ProcessTree.track()
        leaf = spawn(fn -> receive do: (:stop -> :ok) end)
        send(observer, {:policy_ready, self(), leaf})
        wait()
      end)

    on_exit(fn -> Process.exit(root, :kill) end)
    assert_receive {:policy_ready, ^root, leaf}
    references = for pid <- [root, leaf], do: {pid, Process.monitor(pid)}
    worker = AdapterOwner.stop(root, self())
    assert_receive {:parlora_process_stopped, ^worker}

    for {pid, reference} <- references do
      assert_receive {:DOWN, ^reference, :process, ^pid, :killed}
    end
  end

  test "cancelling one task preserves its shared supervisor and sibling branch" do
    {tasks, tree} = task_tree()
    {first, first_leaf} = tracked_task(tasks, tree)
    {second, second_leaf} = tracked_task(tasks, tree)
    worker = AdapterOwner.stop(first, self())
    assert_receive {:parlora_process_stopped, ^worker}
    refute Process.alive?(first)
    refute Process.alive?(first_leaf)
    assert Enum.all?([tasks, tree, second, second_leaf], &Process.alive?/1)
  end

  test "completed tasks release their descendants without retaining task history" do
    {tasks, tree} = task_tree()
    {task, leaf} = tracked_task(tasks, tree)
    reference = Process.monitor(leaf)
    send(task, :finish)
    assert_receive {:DOWN, ^reference, :process, ^leaf, :killed}
    eventually(fn -> snapshot(tasks) == %{tasks => true} end)
    assert Process.alive?(tasks)
  end

  test "concurrent subtree cleanup requests are preserved while trace events settle" do
    {tasks, tree} = task_tree()
    branches = for _ <- 1..4, do: tracked_task(tasks, tree)
    workers = for {task, _leaf} <- branches, do: AdapterOwner.stop(task, self())

    for worker <- workers do
      assert_receive {:parlora_process_stopped, ^worker}
    end

    assert Enum.all?(branches, fn {task, leaf} ->
             not Process.alive?(task) and not Process.alive?(leaf)
           end)

    assert Process.alive?(tasks)
    eventually(fn -> snapshot(tasks) == %{tasks => true} end)
  end

  test "tracker shutdown cleans registered roots and descendants" do
    Process.flag(:trap_exit, true)
    {:ok, tracker} = GenServer.start_link(ProcessTree, [])
    on_exit(fn -> if Process.alive?(tracker), do: GenServer.stop(tracker) end)
    observer = self()

    root =
      spawn(fn ->
        receive do
          :start ->
            leaf = spawn(fn -> receive do: (:stop -> :ok) end)
            send(observer, {:shutdown_leaf, leaf})
            wait()
        end
      end)

    assert ^root = GenServer.call(tracker, {:register, root, false})
    send(root, :start)
    assert_receive {:shutdown_leaf, leaf}
    references = for pid <- [tracker, root, leaf], do: {pid, Process.monitor(pid)}
    Process.exit(tracker, :shutdown)

    for {pid, reference} <- references do
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
    end
  end

  defp task_tree do
    {:ok, tasks} = Task.Supervisor.start_link()
    tree = ProcessTree.register(tasks, tasks: true)
    on_exit(fn -> resume_and_stop(tree) end)
    {tasks, tree}
  end

  defp tracked_task(tasks, tree) do
    observer = self()

    {:ok, task} =
      Task.Supervisor.start_child(tasks, fn ->
        ProcessTree.track(tree)
        leaf = spawn(fn -> receive do: (:stop -> :ok) end)
        send(observer, {:tracked_task, self(), leaf})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:tracked_task, ^task, leaf}
    {task, leaf}
  end

  defp tree do
    observer = self()

    root =
      spawn(fn ->
        Process.put(:observer, observer)
        wait()
      end)

    tree = ProcessTree.register(root)
    on_exit(fn -> resume_and_stop(tree) end)
    {root, tree}
  end

  defp snapshot(root) do
    session = :sys.get_state(ProcessTree).session
    reference = :trace.delivered(session, root)
    assert_receive {:trace_delivered, ^root, ^reference}
    GenServer.call(ProcessTree, {:snapshot, root})
  end

  defp resume_and_stop(tree) do
    try do
      :sys.resume(ProcessTree)
    catch
      :exit, _reason -> :ok
    end

    ProcessTree.stop(tree)
  end

  defp wait do
    receive do
      {:run, function} ->
        function.()
        wait()

      :stop ->
        :ok

      _message ->
        wait()
    end
  end

  defp assert_descendants_stopped do
    receive do
      {:spawned, pid} ->
        refute Process.alive?(pid)
        assert_descendants_stopped()
    after
      0 -> :ok
    end
  end

  defp eventually(function, remaining \\ 200)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, remaining) do
    unless function.() do
      Process.sleep(5)
      eventually(function, remaining - 1)
    end
  end
end
