defmodule Parlora.TestSupport.AudioBenchmark.Replay do
  @moduledoc false
  alias Parlora.{AdapterInit, AudioFormat, AudioPipeline, Limits, OutputSpace, Playout}
  alias Parlora.TestSupport.AudioBenchmark.{Gaps, Packet, Scenarios, Source}
  alias Parlora.TestSupport.MemoryAudio

  def run(scenario, phase \\ 0, options \\ []) do
    Task.async(fn -> replay(scenario, phase, options) end) |> Task.await(60_000)
  end

  def timing(_event, measurements, metadata, session) do
    if metadata.session_id == session, do: Process.put(:benchmark_delay, measurements.delay_ms)
  end

  defp replay(scenario, phase, options) do
    init = %AdapterInit{
      session_id: Parlora.ID.new(),
      adapter_id: "benchmark",
      generation: 0,
      audio_format: %AudioFormat{},
      limits: Keyword.get(options, :limits, %Limits{}),
      event_sink: self()
    }

    {:ok, source} = Source.start_link(init)
    {:ok, destination} = MemoryAudio.start_link(init, :channel, output_space: true)
    {:ok, _} = MemoryAudio.capabilities(destination)

    pipeline_module = Keyword.get(options, :pipeline, AudioPipeline)

    {:ok, pipeline} =
      pipeline_module.init(
        init: init,
        direction: :output,
        source: {Source, source},
        destination: {MemoryAudio, destination},
        output_pacing: :channel
      )

    handler = make_ref()

    :ok =
      :telemetry.attach(handler, [:parlora, :audio, :tick], &__MODULE__.timing/4, init.session_id)

    state = initial(scenario, source, destination, pipeline, options, init.limits)
    last = drain_deadline(scenario)

    result =
      try do
        Enum.reduce_while(0..last//1_000, state, fn now, state ->
          next =
            state |> arrive(now) |> transfer(now, scenario.stall) |> play(now, phase) |> sample()

          if next.failure, do: {:halt, next}, else: {:cont, next}
        end)
      after
        :telemetry.detach(handler)
        GenServer.stop(source)
        GenServer.stop(destination)
      end

    if result.pipeline.tick_timer, do: Process.cancel_timer(result.pipeline.tick_timer)
    summarize(result, scenario, phase)
  end

  defp drain_deadline(scenario) do
    # Bursty providers can finish sending seconds before the last sample plays.
    # Bound the drain by the whole causal source timeline, not last receipt alone.
    max(elem(List.last(scenario.events), 0), Scenarios.timeline(scenario).causal_finish_us) +
      1_500_000
  end

  defp initial(scenario, source, destination, pipeline, options, limits) do
    policy = Keyword.get(options, :policy, Playout)

    %{
      arrivals: scenario.events,
      source: source,
      destination: destination,
      pipeline: pipeline,
      pipeline_module: Keyword.get(options, :pipeline, AudioPipeline),
      limits: limits,
      next_tick: 0,
      policy: policy,
      playout: new_playout(policy, options, limits),
      startup_limit_us: Keyword.get(options, :startup_limit_ms, 150) * 1_000,
      packet: %Packet{},
      rendered_source_bytes: 0,
      peak_staged_bytes: 0,
      output: [],
      rendered: [],
      start_us: nil,
      finish_us: nil,
      max_playout_age_us: 0,
      silence_us: 0,
      internal_padding_bytes: 0,
      recovery_silence_us: 0,
      gaps: %Gaps{},
      peak_provider: 0,
      peak_channel: 0,
      peak_pending: 0,
      failure: nil,
      total: byte_size(scenario.pcm),
      last_sequence: -1,
      admission_us: [],
      peak_mailbox: 0
    }
  end

  defp arrive(state, now) do
    {due, rest} = Enum.split_while(state.arrivals, &(elem(&1, 0) <= now))

    Enum.reduce_while(due, %{state | arrivals: rest}, fn {at, pcm}, state ->
      case Source.push(state.source, pcm, at) do
        :ok -> {:cont, sample(state)}
        {:error, error} -> {:halt, %{state | failure: error.code}}
      end
    end)
  end

  defp transfer(state, now, {from, until}) when now >= from and now < until, do: state
  defp transfer(%{failure: failure} = state, _now, _stall) when failure != nil, do: state

  defp transfer(state, now, _stall) do
    ready =
      ready_hint(state.source, state.pipeline.ready_ref) ||
        space_hint(state.destination, Map.get(state.pipeline, :space_ref))

    if ready != nil or now >= state.next_tick do
      :ok = Source.clock(state.source, now)
      message = ready || :tick
      {:noreply, pipeline} = state.pipeline_module.handle_info(message, state.pipeline)
      target = :sys.get_state(state.destination)

      admitted =
        :queue.to_list(target.outbound.items) |> Enum.filter(&(&1.sequence > state.last_sequence))

      latencies = Enum.map(admitted, &(now - &1.timestamp_us))
      sequence = Enum.reduce(admitted, state.last_sequence, &max(&1.sequence, &2))

      %{
        state
        | pipeline: pipeline,
          next_tick: now + Process.get(:benchmark_delay, 10) * 1_000,
          admission_us: latencies ++ state.admission_us,
          last_sequence: sequence,
          playout: observe(state.policy, state.playout, admitted)
      }
    else
      state
    end
  end

  defp ready_hint(source, reference) do
    receive do
      {:parlora_audio_ready, ^source, ^reference} = message -> message
    after
      0 -> nil
    end
  end

  defp space_hint(destination, reference) do
    receive do
      {:parlora_output_space, ^destination, ^reference} = message -> message
    after
      0 -> nil
    end
  end

  defp play(state, now, phase) when rem(now, 10_000) != phase, do: state

  defp play(state, now, _phase) do
    target = :sys.get_state(state.destination)
    previous = state.playout
    policy = state.policy

    playout =
      if target.recovery_release_epoch == 0,
        do: policy.release_recovery(previous),
        else: previous

    {pcm, source, age, queue, playout, packet} =
      Packet.take(
        state.packet,
        target.outbound,
        playout,
        policy,
        state.limits.max_frame_bytes,
        now
      )

    :sys.replace_state(state.destination, fn state ->
      OutputSpace.notify(%{state | outbound: queue, recovery_release_epoch: nil})
    end)

    source? = source != <<>>
    gap? = gap?(source?, state)
    recovery? = gap? and target.outbound.bytes > 0

    padding = internal_padding(source, state)

    %{
      state
      | playout: playout,
        packet: packet,
        rendered_source_bytes: state.rendered_source_bytes + byte_size(source),
        peak_staged_bytes: max(state.peak_staged_bytes, byte_size(packet.pcm)),
        gaps: Gaps.observe(state.gaps, source?, target.outbound.bytes > 0, gap?, now),
        output: if(source?, do: [source | state.output], else: state.output),
        rendered: [pcm | state.rendered],
        start_us: state.start_us || if(source?, do: now),
        finish_us:
          if(source?, do: now + div(byte_size(source) * 1_000_000, 48_000), else: state.finish_us),
        max_playout_age_us: max(state.max_playout_age_us, age),
        silence_us: state.silence_us + if(gap?, do: 10_000, else: 0),
        internal_padding_bytes: state.internal_padding_bytes + padding,
        recovery_silence_us: state.recovery_silence_us + if(recovery?, do: 10_000, else: 0)
    }
  end

  defp gap?(source?, state),
    do: not source? and state.start_us != nil and state.rendered_source_bytes < state.total

  defp internal_padding(source, state) do
    if source != <<>> and state.rendered_source_bytes + byte_size(source) < state.total,
      do: 480 - byte_size(source),
      else: 0
  end

  defp sample(state) do
    {:ok, source} = Source.output_buffer_status(state.source)
    target = :sys.get_state(state.destination)
    pending = Enum.reduce(state.pipeline.pending, 0, &(byte_size(&1.data) + &2))
    {:message_queue_len, mailbox} = Process.info(self(), :message_queue_len)

    %{
      state
      | peak_provider: max(state.peak_provider, source.queued_bytes),
        peak_channel: max(state.peak_channel, target.outbound.bytes),
        peak_pending: max(state.peak_pending, pending),
        peak_mailbox: max(state.peak_mailbox, mailbox)
    }
  end

  defp summarize(state, scenario, phase) do
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
    first = elem(hd(scenario.events), 0)
    startup = if state.start_us, do: state.start_us - first
    overflow? = scenario.name == :overflow

    checks = checks(state, scenario, output, startup, overflow?)

    %{
      scenario: scenario.name,
      seed: scenario.seed,
      phase_us: phase,
      checks: checks,
      passed: Enum.all?(checks, &elem(&1, 1)),
      failure: state.failure,
      source_bytes: byte_size(scenario.pcm),
      played_bytes: byte_size(output),
      startup_us: startup,
      finish_us: state.finish_us,
      completion_lag_us:
        if(state.finish_us, do: state.finish_us - elem(List.last(scenario.events), 0)),
      max_playout_age_us: state.max_playout_age_us,
      inserted_silence_us:
        state.silence_us + div(state.internal_padding_bytes * 1_000_000, 48_000),
      generated_silence_us: state.silence_us,
      internal_padding_us: div(state.internal_padding_bytes * 1_000_000, 48_000),
      recovery_silence_us: state.recovery_silence_us,
      starvation_events: state.playout.starvations,
      buffering: buffering_snapshot(state.policy, state.playout),
      gaps: Enum.reverse(state.gaps.completed),
      admission_p99_us: percentile(state.admission_us),
      peak_provider_bytes: state.peak_provider,
      peak_channel_bytes: state.peak_channel,
      peak_pending_bytes: state.peak_pending,
      peak_staged_bytes: state.peak_staged_bytes,
      peak_mailbox: state.peak_mailbox
    }
  end

  defp checks(state, scenario, output, startup, overflow?) do
    %{
      integrity: overflow? or output == scenario.pcm,
      bounded: bounded?(state),
      outcome: state.failure == if(overflow?, do: :output_overflow),
      startup: overflow? or (is_integer(startup) and startup <= state.startup_limit_us),
      continuity:
        not scenario.normal? or (state.silence_us == 0 and state.internal_padding_bytes == 0),
      cumulative_delay: cumulative_delay?(scenario, state),
      recovery_delay: recovery_delay?(scenario, state),
      cleanup: not Process.alive?(state.source) and not Process.alive?(state.destination)
    }
  end

  defp bounded?(state),
    do:
      state.peak_provider <= state.limits.provider_audio_queue_bytes and
        state.peak_channel <= state.limits.audio_queue_bytes and
        state.peak_pending <= state.limits.max_frame_bytes and
        state.peak_staged_bytes < state.limits.max_frame_bytes

  defp cumulative_delay?(%{name: :late_bursts}, state), do: state.silence_us <= 600_000
  defp cumulative_delay?(_scenario, _state), do: true

  defp recovery_delay?(%{name: :repeated_shortages}, state),
    do:
      if(Map.get(state.playout, :target),
        do: Enum.all?(state.gaps.completed, &adaptive_wait_bounded?/1),
        else: Gaps.ordinary_wait_bounded?(state.gaps)
      )

  defp recovery_delay?(_scenario, _state), do: true

  defp adaptive_wait_bounded?(gap) do
    # A proactive quiet restoration has no source-unavailable interval.
    limit = if gap.source_unavailable_us == 0, do: 210_000, else: 130_000
    gap.recovery_wait_us <= limit
  end

  defp new_playout(policy, options, limits) do
    buffer = Keyword.get(options, :buffer_ms, 120)

    case Keyword.fetch(options, :playback_buffering) do
      {:ok, _mode} -> policy.new(buffer, limits.audio_queue_bytes, options)
      :error -> policy.new(buffer, limits.audio_queue_bytes)
    end
  end

  defp observe(policy, state, frames) do
    if function_exported?(policy, :observe, 2),
      do: Enum.reduce(frames, state, &policy.observe(&2, &1)),
      else: state
  end

  defp buffering_snapshot(policy, state) do
    if function_exported?(policy, :snapshot, 1),
      do: policy.snapshot(state),
      else: Map.take(state, [:buffer_ms])
  end

  defp percentile([]), do: nil

  defp percentile(values),
    do: values |> Enum.sort() |> Enum.fetch!(ceil(length(values) * 0.99) - 1)
end
