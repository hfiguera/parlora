defmodule Parlora.GreetingRefillTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}

  test "captured greeting timings rebuild headroom before three later interruptions" do
    events =
      "test/fixtures/greeting-refill-20261004.json"
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("events")

    initial = %{
      playout: Playout.new(120, 9_600, playback_buffering: :adaptive),
      queue: %AudioQueue{},
      staged: <<>>,
      input: [],
      output: [],
      renders: [],
      started: nil,
      sequence: 0
    }

    result = Enum.reduce(events, initial, &step/2)
    output = result.output |> Enum.reverse() |> IO.iodata_to_binary()
    input = result.input |> Enum.reverse() |> IO.iodata_to_binary()
    assert output == binary_part(input, 0, byte_size(output))
    queued = result.queue.items |> :queue.to_list() |> Enum.map_join(& &1.data)
    assert input == output <> result.staged <> queued
    assert result.started == 2_429_295
    assert result.playout.starvations == 1

    gaps =
      Enum.filter(result.renders, fn {at, source?} -> at >= result.started and not source? end)

    assert Enum.count_until(gaps, 9) == 8
    assert gaps |> Enum.map(&elem(&1, 0)) |> Enum.min() == 3_229_140
    assert gaps |> Enum.map(&elem(&1, 0)) |> Enum.max() < 3_310_000
    assert result.playout.target.target_ms > 120
  end

  defp step(["frame", _admitted_at, receipt, bytes], state) do
    pcm = :binary.copy(<<state.sequence::little-unsigned-16>>, div(bytes, 2))

    frame =
      AudioFrame.pcm(pcm, "greeting", state.sequence,
        timestamp_us: receipt,
        clock: :local_monotonic
      )

    assert {:ok, queue} = AudioQueue.push(state.queue, frame)

    %{
      state
      | queue: queue,
        playout: Playout.observe(state.playout, frame),
        input: [pcm | state.input],
        sequence: state.sequence + 1
    }
  end

  defp step(["render", at, _recorded_source_bytes], state) do
    {pcm, queue, playout, source?} =
      if state.staged == <<>> do
        {pcm, queue, playout} = Playout.take(state.playout, state.queue, 960, at)
        {pcm, queue, playout, playout.source_bytes > state.playout.source_bytes}
      else
        {state.staged, state.queue, state.playout, true}
      end

    <<packet::binary-size(480), rest::binary>> = pcm

    %{
      state
      | queue: queue,
        playout: playout,
        staged: rest,
        output: if(source?, do: [packet | state.output], else: state.output),
        started: state.started || if(source?, do: at),
        renders: [{at, source?} | state.renders]
    }
  end
end
