defmodule Parlora.Validation.CleanupBenchmark do
  alias Parlora.{AdapterInit, AdapterOwner, Limits}
  alias Parlora.TestSupport.MemoryProvider

  def run do
    Process.flag(:trap_exit, true)

    for population <- [0, 20_000] do
      background =
        for _ <- List.duplicate(nil, population), do: spawn(fn -> receive do: (:stop -> :ok) end)

      try do
        for _ <- 1..5, do: sample(false)
        samples = for _ <- 1..30, do: sample(false)
        {_startup, _cleanup, calls} = sample(true)
        startup = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
        cleanup = samples |> Enum.map(&elem(&1, 1)) |> Enum.sort()

        IO.puts(
          JSON.encode!(%{
            background_processes: population,
            startup_median_us: Enum.at(startup, 15),
            cleanup_median_us: Enum.at(cleanup, 15),
            cleanup_p95_us: Enum.at(cleanup, 28),
            calls: calls
          })
        )
      after
        Enum.each(background, &Process.exit(&1, :kill))
      end
    end
  end

  defp sample(traced?) do
    init = %AdapterInit{
      event_sink: self(),
      generation: 0,
      session_id: "cleanup-benchmark",
      adapter_id: "provider",
      limits: %Limits{}
    }

    deadline = System.monotonic_time(:microsecond) + 5_000_000
    session = if traced?, do: trace()
    started = System.monotonic_time(:microsecond)

    {:ok, owner, watcher} =
      AdapterOwner.start_link(fn -> {MemoryProvider, init, [], deadline} end)

    receive do: ({:parlora_adapter_started, ^owner, _adapter} -> :ok)
    ref = Process.monitor(watcher)
    startup = System.monotonic_time(:microsecond) - started
    started = System.monotonic_time(:microsecond)
    AdapterOwner.cancel(watcher)

    receive do
      {:DOWN, ^ref, :process, ^watcher, _} -> :ok
    after
      10_000 -> raise "cleanup timeout"
    end

    elapsed = System.monotonic_time(:microsecond) - started
    calls = if session, do: count_calls(session), else: nil
    flush()
    {startup, elapsed, calls}
  end

  defp trace() do
    session = :trace.session_create(:cleanup_benchmark, self(), [])
    :trace.function(session, {:erlang, :processes, 0}, true, [:local])
    :trace.function(session, {:erlang, :process_info, 2}, true, [:local])
    :trace.function(session, {:trace, :session_destroy, 1}, true, [:local])
    :trace.process(session, self(), true, [:call, :set_on_spawn])
    :trace.process(session, Process.whereis(Parlora.ProcessTree), true, [:call, :set_on_spawn])
    session
  end

  defp count_calls(session) do
    ref = :trace.delivered(session, :all)
    receive do: ({:trace_delivered, :all, ^ref} -> :ok)
    :trace.session_destroy(session)
    drain(%{vm_scans: 0, ancestry_checks: 0, trace_session_destroys: 0})
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp drain(counts) do
    receive do
      {:trace, _, :call, {:erlang, :processes, []}} ->
        drain(Map.update!(counts, :vm_scans, &(&1 + 1)))

      {:trace, _, :call, {:erlang, :process_info, [_, {:dictionary, :"$ancestors"}]}} ->
        drain(Map.update!(counts, :ancestry_checks, &(&1 + 1)))

      {:trace, pid, :call, {:trace, :session_destroy, _arguments}} when pid != self() ->
        drain(Map.update!(counts, :trace_session_destroys, &(&1 + 1)))

      {:trace, _, :call, _} ->
        drain(counts)
    after
      0 -> counts
    end
  end
end

Parlora.Validation.CleanupBenchmark.run()
