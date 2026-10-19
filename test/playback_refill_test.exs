defmodule Parlora.PlaybackRefillTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioPipeline, Limits, Playout}
  alias Parlora.TestSupport.MemoryAudio

  test "recorded provider jitter no longer inserts silence at the two nonzero boundaries" do
    evidence = File.read!("validation/pcm-overflow/starvation-evidence.json") |> JSON.decode!()
    arrivals = Enum.filter(evidence["events"], &(&1["kind"] == "audio_received"))
    old = replay(arrivals, :pipeline, 60)
    fixed = replay(arrivals, :channel, 120)
    assert old.gaps == [300, 1_200, 2_200]
    assert fixed.gaps == [1_200]
    assert fixed.inserted_ms < old.inserted_ms
    assert fixed.start_ms - old.start_ms <= 60
    assert fixed.start_ms <= 120
    assert fixed.peak_bytes <= 9_600
    assert fixed.output == old.output
    assert byte_size(fixed.output) == length(arrivals) * 4_800
  end

  test "bounded recovery avoids the repeated speech gap in the longer live trial" do
    fixture = File.read!("validation/pcm-overflow/refill-trial-arrivals.json") |> JSON.decode!()
    trial = replay(fixture["arrivals"], :channel, 120, false)
    fixed = replay(fixture["arrivals"], :channel, 120)

    assert trial.gaps == [10_100, 11_800]
    assert fixed.gaps == [10_100]
    # Burst admission changes polling phase; compare complete output as well as
    # the number of gaps so a shorter first pause cannot hide a later one.
    assert fixed.inserted_ms - trial.inserted_ms == -50
    assert fixed.peak_bytes <= 9_600

    assert fixed.output == trial.output
  end

  def timing(_name, %{delay_ms: delay}, metadata, session) do
    if metadata.session_id == session, do: Process.put(:refill_delay, delay)
  end

  defp replay(arrivals, pacing, buffer_ms, recovery? \\ true) do
    init = %AdapterInit{
      limits: %Limits{},
      audio_format: %AudioFormat{},
      session_id: Parlora.ID.new(),
      adapter_id: "replay",
      generation: 0,
      event_sink: self()
    }

    {:ok, source} =
      MemoryAudio.start_link(
        %{init | limits: %{init.limits | audio_queue_bytes: 33_600}},
        :provider,
        []
      )

    {:ok, destination} = MemoryAudio.start_link(init, :channel, [])
    {:ok, _caps} = MemoryAudio.capabilities(source)
    {:ok, _caps} = MemoryAudio.capabilities(destination)

    {:ok, pipeline} =
      AudioPipeline.init(
        init: init,
        direction: :output,
        source: {MemoryAudio, source},
        destination: {MemoryAudio, destination},
        output_pacing: pacing
      )

    handler = make_ref()

    :ok =
      :telemetry.attach(handler, [:parlora, :audio, :tick], &__MODULE__.timing/4, init.session_id)

    initial = %{
      arrivals: arrivals,
      seq: 0,
      pipeline: pipeline,
      next_tick: 0,
      playout:
        if(pacing == :channel and recovery?,
          do: Playout.new(buffer_ms, 9_600),
          else: %Playout{buffer_ms: buffer_ms}
        ),
      output: <<>>,
      gaps: [],
      start_ms: nil,
      peak_bytes: 0,
      inserted_ms: 0
    }

    try do
      result =
        Enum.reduce(0..(List.last(arrivals)["at_us"] + 1_000_000)//1_000, initial, fn now,
                                                                                      state ->
          state |> arrive(source, now) |> transfer(now) |> play(destination, now)
        end)

      Process.cancel_timer(result.pipeline.tick_timer)
      result
    after
      :telemetry.detach(handler)
      GenServer.stop(source)
      GenServer.stop(destination)
    end
  end

  defp arrive(state, source, now) do
    {due, rest} = Enum.split_while(state.arrivals, &(&1["at_us"] <= now))
    count = div(Enum.reduce(due, 0, &(&1["bytes"] + &2)), 480)

    for index <- Enum.take(Stream.iterate(state.seq, &(&1 + 1)), count) do
      frame = AudioFrame.pcm(:binary.copy(<<index::little-16>>, 240), "replay", index)
      :ok = MemoryAudio.audio(source, frame)
    end

    %{state | arrivals: rest, seq: state.seq + count}
  end

  defp transfer(%{next_tick: next} = state, now) when now < next, do: state

  defp transfer(state, now) do
    {:noreply, pipeline} = AudioPipeline.handle_info(:tick, state.pipeline)
    %{state | pipeline: pipeline, next_tick: now + Process.get(:refill_delay) * 1_000}
  end

  defp recovery(playout, %{recovery_release_epoch: 0}), do: Playout.release_recovery(playout)
  defp recovery(playout, _target), do: playout

  defp play(state, _destination, now) when rem(now, 10_000) != 0, do: state

  defp play(state, destination, now) do
    target = :sys.get_state(destination)
    queue = target.outbound

    {pcm, remaining, playout} = Playout.take(recovery(state.playout, target), queue, 480, now)
    :sys.replace_state(destination, &%{&1 | outbound: remaining, recovery_release_epoch: nil})
    source? = playout.source_bytes > state.playout.source_bytes
    gap? = playout.starvations > state.playout.starvations and state.arrivals != []

    %{
      state
      | playout: playout,
        peak_bytes: max(state.peak_bytes, queue.bytes),
        output: if(source?, do: state.output <> pcm, else: state.output),
        start_ms: state.start_ms || if(source?, do: div(now, 1_000)),
        inserted_ms:
          state.inserted_ms +
            if(not source? and state.start_ms != nil and state.arrivals != [], do: 10, else: 0),
        gaps: if(gap?, do: state.gaps ++ [div(playout.source_bytes, 48)], else: state.gaps)
    }
  end
end
