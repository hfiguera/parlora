defmodule Parlora.AdapterCleanupScalingTest do
  use ExUnit.Case, async: false
  alias Parlora.{AdapterInit, AdapterOwner, AudioPipeline, Limits}
  alias Parlora.TestSupport.MemoryProvider

  defmodule StalledSource do
    def read_audio(observer, _budget) do
      :proc_lib.spawn(fn ->
        Process.flag(:trap_exit, true)
        send(observer, {:pipeline_leaf, self()})
        receive do: (:stop -> :ok)
      end)

      receive do: (:release -> {:ok, []})
    end
  end

  test "pipeline startup cleanup includes unlinked descendants of adapter callbacks" do
    Process.flag(:trap_exit, true)

    init = %AdapterInit{
      session_id: "pipeline-cleanup",
      adapter_id: "pipeline",
      generation: 0,
      event_sink: self(),
      limits: %Limits{}
    }

    {:ok, pipeline} =
      AudioPipeline.start_link(
        init: init,
        direction: :input,
        startup_owner: self(),
        startup_token: make_ref(),
        source: {StalledSource, self()},
        destination: {MemoryProvider, self()}
      )

    on_exit(fn -> AdapterOwner.stop(pipeline, nil) end)
    assert_receive {:pipeline_leaf, leaf}
    references = for pid <- [pipeline, leaf], do: {pid, Process.monitor(pid)}
    worker = AdapterOwner.stop(pipeline, self())
    assert_receive {:parlora_process_stopped, ^worker}

    for {pid, reference} <- references do
      assert_receive {:DOWN, ^reference, :process, ^pid, :killed}
    end
  end

  test "adapter cleanup never enumerates unrelated VM processes" do
    Process.flag(:trap_exit, true)
    background = for _ <- 1..2_000, do: spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Enum.each(background, &Process.exit(&1, :kill)) end)
    tracing = :trace.session_create(:cleanup_scaling_test, self(), [])
    on_exit(fn -> :trace.session_destroy(tracing) end)
    :trace.function(tracing, {:erlang, :processes, 0}, true, [:local])
    :trace.function(tracing, {:trace, :session_destroy, 1}, true, [:local])
    :trace.process(tracing, self(), true, [:call, :set_on_spawn])
    :trace.process(tracing, Process.whereis(Parlora.ProcessTree), true, [:call, :set_on_spawn])

    init = %AdapterInit{
      event_sink: self(),
      generation: 0,
      session_id: "cleanup-scaling",
      adapter_id: "provider",
      limits: %Limits{}
    }

    deadline = System.monotonic_time(:microsecond) + 5_000_000

    {:ok, owner, watcher} =
      AdapterOwner.start_link(fn -> {MemoryProvider, init, [], deadline} end)

    on_exit(fn -> AdapterOwner.cancel(watcher) end)
    assert_receive {:parlora_adapter_started, ^owner, adapter}
    monitors = for pid <- [owner, adapter, watcher], do: {pid, Process.monitor(pid)}
    AdapterOwner.cancel(watcher)

    for {pid, reference} <- monitors do
      assert_receive {:DOWN, ^reference, :process, ^pid, _reason}
    end

    reference = :trace.delivered(tracing, :all)
    assert_receive {:trace_delivered, :all, ^reference}
    refute_received {:trace, _pid, :call, {:erlang, :processes, []}}
    refute_received {:trace, _pid, :call, {:trace, :session_destroy, _arguments}}
    :trace.session_destroy(tracing)
    assert Enum.all?(background, &Process.alive?/1)
  end
end
