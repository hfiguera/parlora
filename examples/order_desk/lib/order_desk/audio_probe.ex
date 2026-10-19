defmodule OrderDesk.AudioProbe do
  @moduledoc "Bounded, offline device timing experiment; no microphone audio is retained."
  alias OrderDesk.ScriptedProvider
  alias Parlora.Channels.LocalAudio
  alias Parlora.Event

  @events [[:parlora, :audio, :poll], [:parlora, :audio, :tick], [:parlora, :audio, :playout]]

  def run do
    reports = Enum.map([:baseline, :cpu_load, :injected_stall], &run_case/1)
    IO.puts(JSON.encode!(%{schedulers: System.schedulers_online(), cases: reports}))
  end

  def record(event, measurements, metadata, table) do
    index = :ets.update_counter(table, :rows, 1, {:rows, 0})

    if index <= 40_000 do
      :ets.insert(table, {index, now(), List.last(event), measurements, metadata})
    end

    if List.last(event) == :poll, do: :ets.insert(table, {:channel, self()})
  end

  defp run_case(kind) do
    table = :ets.new(:audio_probe, [:ordered_set, :public])
    handler = make_ref()
    :ok = :telemetry.attach_many(handler, @events, &__MODULE__.record/4, table)
    started = now()

    {:ok, session} =
      OrderDesk.start_session(
        {LocalAudio, device_options()},
        {ScriptedProvider, observer: self(), audio: false}
      )

    workers = if kind == :cpu_load, do: load_workers(), else: []

    try do
      provider =
        receive do
          {:scripted_provider, pid} -> pid
        after
          5_000 -> raise "Provider startup timed out"
        end

      receive do
        {:parlora_event, %Event{source: :session, type: :ready}} -> :ok
      after
        5_000 -> raise "Session startup timed out"
      end

      # Two ten-second source intervals, separated by three seconds of silence.
      steps = [{1_000, :tone}, {11_000, :quiet}, {14_000, :tone}, {24_000, :finish}]
      steps = if kind == :injected_stall, do: [{5_000, :stall} | steps], else: steps
      Enum.each(steps, fn {ms, action} -> Process.send_after(self(), {:probe, action}, ms) end)
      {transitions, events} = collect(provider, table, started, [], [])
      :ok = Parlora.close(session, :finish)

      receive do
        {:parlora_event, %Event{source: :session, type: :closed}} -> :ok
      after
        6_000 -> raise "Session close timed out"
      end

      [{:rows, count}] = :ets.lookup(table, :rows)
      if count > 40_000, do: raise("Probe sample bound exceeded")

      rows =
        for {_, time, type, metrics, meta} <- :ets.tab2list(table),
            do: %{at_us: time - started, type: type, metrics: metrics, meta: meta}

      report(kind, rows, Enum.reverse(transitions), Enum.reverse(events), length(workers))
    after
      Enum.each(workers, fn pid ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end)

      if Process.alive?(session), do: Parlora.close(session)
      wait_cleanup(System.monotonic_time(:millisecond) + 5_000)
      :telemetry.detach(handler)
      :ets.delete(table)
      flush()
    end
  end

  defp collect(provider, table, started, transitions, events) do
    receive do
      {:probe, :finish} ->
        {[%{at_us: now() - started, action: :finish} | transitions], events}

      {:probe, :stall} ->
        [{:channel, pid}] = :ets.lookup(table, :channel)
        :ok = :sys.suspend(pid)

        try do
          Process.sleep(150)
        after
          :ok = :sys.resume(pid)
        end

        collect(provider, table, started, transitions, events)

      {:probe, action} when action in [:tone, :quiet] ->
        :ok = ScriptedProvider.audio(provider, action == :tone)
        transition = %{at_us: now() - started, action: action}
        collect(provider, table, started, [transition | transitions], events)

      {:parlora_event, %Event{type: :audio_discontinuity} = event} ->
        row = %{at_us: event.observed_at_us - started, payload: event.payload}
        collect(provider, table, started, transitions, Enum.take([row | events], 200))

      {:parlora_event, %Event{type: type}} when type in [:failed, :closed] ->
        raise "Unexpected adapter #{type} during audio probe"

      _other ->
        collect(provider, table, started, transitions, events)
    after
      30_000 -> raise "Probe exceeded its receive deadline"
    end
  end

  defp report(kind, rows, transitions, events, workers) do
    first_tone = hd(transitions).at_us
    polls = Enum.filter(rows, &(&1.type == :poll and &1.at_us > first_tone))
    baseline = rows |> Enum.filter(&(&1.type == :poll and &1.at_us <= first_tone)) |> List.last()
    final = List.last(polls).metrics

    windows =
      transitions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [left, right] ->
        if left.action == :tone, do: [{left.at_us + 300_000, right.at_us - 100_000}], else: []
      end)

    gaps =
      Enum.filter(rows, fn row ->
        row.type == :playout and row.metrics.silence_bytes > 0 and
          Enum.any?(windows, fn {first, last} -> row.at_us >= first and row.at_us <= last end)
      end)

    output_ticks = Enum.filter(rows, &(&1.type == :tick and &1.meta.direction == :output))

    %{
      scenario: kind,
      cpu_workers: workers,
      samples: length(rows),
      poll_gap_us: distribution(polls, & &1.metrics.poll_gap_us),
      capture_us: distribution(polls, & &1.metrics.last_capture_us),
      playback_us: distribution(polls, & &1.metrics.last_playback_us),
      observe_us: distribution(polls, & &1.metrics.last_observe_us),
      output_tick_late_us: distribution(output_ticks, & &1.metrics.late_us),
      steady_native_underrun_frames:
        final.output_underrun_frames - baseline.metrics.output_underrun_frames,
      steady_native_capture_dropped_frames:
        final.capture_dropped_frames - baseline.metrics.capture_dropped_frames,
      output_rate: final.output_rate,
      input_rate: final.input_rate,
      interior_source_silence_ms:
        Enum.reduce(gaps, 0, fn row, sum -> sum + row.metrics.silence_bytes / 48 end),
      transitions: transitions,
      discontinuities: events
    }
  end

  defp distribution(rows, getter) do
    values = Enum.sort(Enum.map(rows, getter))

    Map.new([50, 95, 99, 100], fn percentile ->
      {"p#{percentile}", Enum.at(values, max(0, ceil(length(values) * percentile / 100) - 1))}
    end)
  end

  defp load_workers do
    for _ <- 1..min(4, max(1, div(System.schedulers_online(), 4))),
        do: spawn_link(fn -> load_loop() end)
  end

  defp load_loop do
    busy_until(now() + 20_000)
    Process.sleep(20)
    load_loop()
  end

  defp busy_until(deadline) do
    Enum.reduce(1..1_000, 0, fn x, acc -> rem(x * x + acc, 10_007) end)
    if now() < deadline, do: busy_until(deadline)
  end

  defp device_options do
    host =
      System.get_env(
        "CPAL_HOST",
        if(:os.type() == {:unix, :darwin}, do: "CoreAudio", else: "PulseAudio")
      )

    {:ok, devices} = LocalAudio.devices(host)

    Enum.reduce(
      [{:input, "CPAL_INPUT", :input_device}, {:output, "CPAL_OUTPUT", :output_device}],
      [host: host],
      fn {direction, env, key}, options ->
        case System.get_env(env) do
          nil ->
            options

          name ->
            device =
              Enum.find(devices, &(&1.name == name and Map.fetch!(&1, direction) != nil)) ||
                raise "Device not found"

            Keyword.put(options, key, device.id)
        end
      end
    )
  end

  defp wait_cleanup(deadline) do
    if DynamicSupervisor.count_children(Parlora.Sessions).active > 0 do
      if System.monotonic_time(:millisecond) >= deadline, do: raise("Session cleanup timed out")
      Process.sleep(5)
      wait_cleanup(deadline)
    end
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
end
