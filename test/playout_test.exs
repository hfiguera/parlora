defmodule Parlora.PlayoutTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue}
  alias Parlora.Playout

  test "a 60 ms cushion preserves continuous media across 20 ms delivery jitter" do
    immediate = replay(0)
    buffered = replay(60)
    assert gaps(immediate) > 0
    assert gaps(buffered) == 0
    expected = for i <- 0..199, into: <<>>, do: :binary.copy(<<i, 0>>, 240)
    assert media(buffered) == expected
  end

  test "short audio starts after the bounded wait even without another frame" do
    {:ok, queue} = AudioQueue.push(%AudioQueue{}, frame(1))
    {silence, queue, state} = Playout.take(%Playout{}, queue, 480, 0)
    assert silence == :binary.copy(<<0>>, 480)
    assert queue.bytes == 480
    {pcm, queue, state} = Playout.take(state, queue, 480, 60_000)
    assert pcm == frame(1).data
    assert queue.bytes == 0
    assert state.playing?
  end

  test "starvation re-buffers once per gap and clear resets the playback state" do
    {:ok, queue} = AudioQueue.push(%AudioQueue{}, frame(1))
    {_pcm, queue, state} = Playout.take(%Playout{buffer_ms: 0}, queue, 480, 0)
    {_silence, queue, state} = Playout.take(state, queue, 480, 10_000)
    assert state.starvations == 1
    {_silence, _queue, state} = Playout.take(state, queue, 480, 20_000)
    assert state.starvations == 1

    {:ok, queue} = AudioQueue.push(queue, frame(2))
    {_pcm, queue, state} = Playout.take(state, queue, 480, 30_000)
    {_silence, _queue, state} = Playout.take(Playout.reset(state), queue, 480, 40_000)
    assert state.starvations == 1
    refute state.playing?
  end

  test "recovery is bounded, preserves short tails, and clear restores initial buffering" do
    state = Playout.new(120, 9_600)
    {:ok, queue} = AudioQueue.push(%AudioQueue{}, frame(1))
    {_silence, queue, state} = Playout.take(state, queue, 480, 0)
    {_pcm, queue, state} = Playout.take(state, queue, 480, 120_000)
    {_silence, queue, state} = Playout.take(state, queue, 480, 130_000)
    assert state.recovering?
    {:ok, queue} = AudioQueue.push(queue, frame(2))
    {_silence, queue, state} = Playout.take(state, queue, 480, 200_000)
    {_silence, queue, state} = Playout.take(state, queue, 480, 289_999)
    assert queue.bytes == 480
    {pcm, queue, state} = Playout.take(state, queue, 480, 290_000)
    assert pcm == frame(2).data
    assert queue.bytes == 0
    {_silence, _queue, state} = Playout.take(state, queue, 480, 330_000)
    refute Playout.reset(state).recovering?
    assert Playout.new(20, 1_920).recovery_ms == 40
    assert Playout.new(0, 9_600).recovery_ms == 0
  end

  test "recovery deadline follows shortage within the configured cap without restarting" do
    for {shortage_ms, expected_hold} <- [{30, 50}, {70, 90}, {190, 120}, {500, 120}] do
      state = %{Playout.new(120, 9_600) | playing?: true}
      {_silence, empty, state} = Playout.take(state, %AudioQueue{}, 480, 0)
      {_silence, empty, state} = Playout.take(state, empty, 480, 10_000)
      assert state.starvations == 1
      assert state.empty_since_us == 0
      {:ok, queue} = AudioQueue.push(empty, frame(7))
      returned = shortage_ms * 1000
      deadline = returned + expected_hold * 1000
      {_silence, queue, state} = Playout.take(state, queue, 480, returned)
      {_silence, queue, state} = Playout.take(state, queue, 480, deadline - 1)
      assert state.source_bytes == 0
      assert queue.bytes == 480
      {pcm, empty, state} = Playout.take(state, queue, 480, deadline)
      assert pcm == frame(7).data
      assert empty.bytes == 0
      assert state.empty_since_us == nil
      assert state.waiting_since_us == nil
      refute state.recovering?
    end
  end

  test "a full recovery cushion releases immediately and preserves samples" do
    state = %{Playout.new(120, 9_600) | recovering?: true, empty_since_us: -100_000}
    frames = Enum.map(1..20, &frame/1)

    queue =
      Enum.reduce(frames, %AudioQueue{}, fn frame, queue ->
        {:ok, queue} = AudioQueue.push(queue, frame)
        queue
      end)

    {pcm, queue, state} = Playout.take(state, queue, 480, 0)
    assert pcm == frame(1).data
    assert state.release_reason == :queue_ready
    {rest, queue} = AudioQueue.pop(queue, 9_600)
    assert pcm <> Enum.map_join(rest, & &1.data) == Enum.map_join(frames, & &1.data)
    assert queue.bytes == 0
  end

  test "refill targets depend on shortage rather than maximum storage" do
    for capacity <- [9_600, 19_200], shortage <- [20_000, 100_000] do
      state = %{Playout.new(120, capacity) | playing?: true}
      {_silence, queue, state} = Playout.take(state, %AudioQueue{capacity: capacity}, 480, 0)

      queue =
        Enum.reduce(1..10, queue, fn i, queue ->
          {:ok, queue} = AudioQueue.push(queue, frame(i))
          queue
        end)

      {pcm, queue, state} = Playout.take(state, queue, 480, shortage)

      if shortage == 20_000 do
        assert pcm == frame(1).data
        assert state.source_bytes == 480
        assert state.release_reason == :queue_ready
        assert queue.bytes == 4_320
      else
        assert state.source_bytes == 0
        {pcm, _, state} = Playout.take(state, queue, 480, shortage + 120_000)
        assert pcm == frame(1).data
        assert state.source_bytes == 480
        assert state.release_reason == :deadline
      end
    end

    assert Playout.new(120, 1_920).recovery_bytes == 1_920
    assert Playout.new(0, 9_600).recovery_bytes == 0
  end

  defp replay(buffer_ms) do
    {_source, _queue, _state, output} =
      Enum.reduce(0..215, {[], %AudioQueue{}, %Playout{buffer_ms: buffer_ms}, []}, fn tick,
                                                                                      {source,
                                                                                       queue,
                                                                                       state,
                                                                                       output} ->
        chunk = div(tick, 10)
        arrival = chunk * 10 + if(rem(chunk, 2) == 1, do: 2, else: 0)

        source =
          if chunk < 20 and tick == arrival,
            do: source ++ Enum.map((chunk * 10)..(chunk * 10 + 9), &frame/1),
            else: source

        {source, queue} =
          case source do
            [frame | rest] ->
              {:ok, queue} = AudioQueue.push(queue, frame)
              {rest, queue}

            [] ->
              {[], queue}
          end

        {pcm, queue, next} = Playout.take(state, queue, 480, tick * 10_000)
        actual? = next.source_bytes > state.source_bytes
        {source, queue, next, output ++ [{actual?, pcm}]}
      end)

    output
  end

  defp gaps(output) do
    output
    |> Enum.drop_while(&(not elem(&1, 0)))
    |> Enum.reverse()
    |> Enum.drop_while(&(not elem(&1, 0)))
    |> Enum.count(&(not elem(&1, 0)))
  end

  defp media(output), do: output |> Enum.filter(&elem(&1, 0)) |> Enum.map_join(&elem(&1, 1))
  defp frame(i), do: AudioFrame.pcm(:binary.copy(<<i, 0>>, 240), "tone", i)
end
