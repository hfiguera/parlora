defmodule Parlora.TestSupport.BrowserRecoveryReplay do
  @moduledoc false
  alias Parlora.{AdapterInit, AudioFormat, AudioPipeline, Limits}
  alias Parlora.Channels.Browser.Media
  alias Parlora.Provider.OutputBuffer
  alias Parlora.TestSupport.MemoryAudio

  def run do
    evidence = File.read!("validation/browser-recovery-overflow/evidence.json") |> Jason.decode!()

    init = %AdapterInit{
      session_id: "recovery-replay",
      adapter_id: "replay",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    exact(evidence, init)
    arrivals = Enum.filter(evidence["events"], &(&1["kind"] == "received"))

    results =
      for phase <- 0..9_000//1_000, policy <- [:fixed_hold, :queue, :none, :pressure, :cushion] do
        model(init, arrivals, policy, phase)
      end

    for result <- results do
      if result.policy == :fixed_hold do
        true = result.failure.code == :output_overflow
      else
        true = result.failure == nil
        true = result.played_bytes == 52_800
      end

      true = result.peak_channel_bytes <= 9_600
      true = result.peak_provider_bytes <= 33_600
    end

    results
  end

  defp exact(evidence, init) do
    {last, events} = List.pop_at(evidence["events"], -1)

    {queue, sequence} =
      Enum.reduce(events, {OutputBuffer.new(init.limits), 0}, fn event, {queue, sequence} ->
        if event["kind"] == "received" do
          true = queue.bytes == event["queue_bytes"]

          {:ok, result} =
            OutputBuffer.push(
              queue,
              pcm(sequence, event["bytes"]),
              init,
              sequence,
              event["at_us"]
            )

          result
        else
          {:ok, frames, next} = OutputBuffer.read(queue, 960, init.limits, event["at_us"])
          true = Enum.reduce(frames, 0, &(byte_size(&1.data) + &2)) == event["bytes"]
          true = next.bytes == event["queue_bytes"]
          {next, sequence}
        end
      end)

    true = queue.bytes == 31_680

    {:error, %{code: :output_overflow}} =
      OutputBuffer.push(queue, pcm(sequence, last["bytes"]), init, sequence, last["at_us"])

    true = queue.bytes + last["bytes"] == 36_480
    :ok
  end

  def timing(_name, measurements, _metadata, _config),
    do: Process.put(:transfer_delay, measurements.delay_ms)

  defp model(init, arrivals, policy, phase) do
    recovery = %{fixed_hold: 200, queue: nil, none: 0, pressure: 200, cushion: 200}[policy]

    {:ok, source} =
      MemoryAudio.start_link(
        %{init | limits: %{init.limits | audio_queue_bytes: 33_600}},
        :provider,
        pressure_status: policy in [:pressure, :cushion]
      )

    {:ok, destination} = MemoryAudio.start_link(init, :channel, [])
    {:ok, _} = MemoryAudio.capabilities(source)
    {:ok, _} = MemoryAudio.capabilities(destination)

    {:ok, pipeline} =
      AudioPipeline.init(
        init: init,
        direction: :output,
        source: {MemoryAudio, source},
        destination: {MemoryAudio, destination},
        output_pacing: :channel
      )

    media =
      Media.open(init, %{
        jitter_ms: 0,
        max_rtp_packets: 32,
        max_age_ms: 200,
        playback_buffer_ms: 120
      })

    # Keep the historical 200 ms hold explicit; production now uses 120 ms.
    buffer_ms = if policy == :fixed_hold, do: 200, else: 120

    media = %{
      media
      | playout: %{
          media.playout
          | buffer_ms: buffer_ms,
            independent_recovery?: false,
            recovering?: true,
            recovery_ms: recovery,
            recovery_bytes: if(policy == :cushion, do: media.playout.recovery_bytes, else: nil)
        }
    }

    handler = make_ref()
    :ok = :telemetry.attach(handler, [:parlora, :audio, :tick], &__MODULE__.timing/4, nil)

    state = %{
      arrivals: arrivals,
      seq: 0,
      pipeline: pipeline,
      media: %{init: init, media: media},
      next_tick: 0,
      next_play: phase,
      failure: nil,
      peak_provider: 0,
      peak_channel: 0,
      first_play_us: nil,
      blocked_ticks: 0,
      source: source,
      destination: destination
    }

    try do
      final =
        Enum.reduce_while(0..2_000_000//1_000, state, fn now, state ->
          state = state |> arrivals(init, now) |> transfer(now) |> playback(now)
          if state.failure, do: {:halt, state}, else: {:cont, state}
        end)

      %{
        policy: policy,
        recovery_ms: recovery,
        browser_tick_phase_us: phase,
        failure: final.failure,
        peak_provider_bytes: final.peak_provider,
        peak_channel_bytes: final.peak_channel,
        first_source_play_us: final.first_play_us,
        blocked_ticks: final.blocked_ticks,
        played_bytes: final.media.media.playout.source_bytes
      }
    after
      :telemetry.detach(handler)
      Media.close(media)
      GenServer.stop(source)
      GenServer.stop(destination)
    end
  end

  defp arrivals(state, init, now) do
    {due, rest} = Enum.split_while(state.arrivals, &(&1["at_us"] <= now))

    Enum.reduce(due, %{state | arrivals: rest}, fn arrival, state ->
      queue = :sys.get_state(state.source).inbound

      case OutputBuffer.push(queue, pcm(state.seq, arrival["bytes"]), init, state.seq, now) do
        {:ok, {queue, sequence}} ->
          :sys.replace_state(state.source, &%{&1 | inbound: queue})
          %{state | seq: sequence, peak_provider: max(state.peak_provider, queue.bytes)}

        {:error, error} ->
          %{state | failure: %{code: error.code, at_us: now, queue_bytes: queue.bytes}}
      end
    end)
  end

  defp transfer(%{next_tick: next} = state, now) when now < next, do: state

  defp transfer(state, now) do
    {:noreply, pipeline} = AudioPipeline.handle_info(:tick, state.pipeline)

    %{
      state
      | pipeline: pipeline,
        next_tick: now + Process.get(:transfer_delay) * 1_000,
        blocked_ticks: state.blocked_ticks + if(pipeline.blocked_since_us, do: 1, else: 0)
    }
  end

  defp playback(%{next_play: next} = state, now) when now < next, do: state

  defp playback(state, now) do
    destination = :sys.get_state(state.destination)
    queue = destination.outbound

    current =
      if destination.recovery_release_epoch == state.media.media.epoch,
        do: Media.release_recovery(state.media, destination.recovery_release_epoch),
        else: state.media

    {_packet, media} =
      Media.output(%{current | media: %{current.media | outbound: queue}}, now)

    :sys.replace_state(
      state.destination,
      &%{&1 | outbound: media.media.outbound, recovery_release_epoch: nil}
    )

    %{
      state
      | media: media,
        next_play: now + 10_000,
        peak_channel: max(state.peak_channel, queue.bytes),
        first_play_us: state.first_play_us || if(media.media.playout.source_bytes > 0, do: now)
    }
  end

  defp pcm(sequence, bytes), do: :binary.copy(<<rem(sequence, 65_536)::little-16>>, div(bytes, 2))
end
