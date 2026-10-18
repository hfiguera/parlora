defmodule Parlora.PlayoutRecoveryTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}

  test "adaptive recovery rebuilds learned headroom but releases short tails by the deadline" do
    state = %{Playout.new(120, 9_600, playback_buffering: :adaptive) | playing?: true}
    state = %{state | target: %{state.target | target_ms: 145}}
    {_, queue, state} = Playout.take(state, %AudioQueue{}, 960, 0)
    queue = append(queue, 100)
    {_, queue, state} = Playout.take(state, queue, 960, 30_000)
    assert state.buffer_ms == 145
    assert state.source_bytes == 0
    {_, queue, state} = Playout.take(state, queue, 960, 79_999)
    assert queue.bytes == 4_800
    assert state.source_bytes == 0
    {_, _, state} = Playout.take(state, queue, 960, 80_000)
    assert state.source_bytes == 960
    assert state.release_reason == :deadline
  end

  test "learned cushion releases when filled, while floor and fixed recovery stay prompt" do
    for mode <- [:fixed, :adaptive] do
      state = %{Playout.new(120, 9_600, playback_buffering: mode) | playing?: true}
      {_, queue, state} = Playout.take(state, %AudioQueue{}, 960, 0)
      queue = append(queue, 100)
      {_, _, state} = Playout.take(state, queue, 960, 30_000)
      assert state.source_bytes == 960
      assert state.release_reason == :queue_ready
    end

    state = %{Playout.new(120, 9_600, playback_buffering: :adaptive) | playing?: true}
    state = %{state | target: %{state.target | target_ms: 190}}
    {_, queue, state} = Playout.take(state, %AudioQueue{}, 960, 0)
    queue = append(queue, 100)
    {_, queue, state} = Playout.take(state, queue, 960, 30_000)
    queue = append(queue, 90)
    {_, _, state} = Playout.take(state, queue, 960, 40_000)
    assert state.source_bytes == 960
    assert state.release_reason == :queue_ready
  end

  test "recorded shortage resumes as soon as the queued cushion is sufficient" do
    state = %{Playout.new(120, 9_600) | playing?: true}
    {_, queue, state} = Playout.take(state, %AudioQueue{}, 960, 0)
    queue = append(queue, 40)
    {_, queue, state} = Playout.take(state, queue, 960, 31_000)
    assert state.source_bytes == 0
    queue = append(queue, 50)
    {pcm, queue, state} = Playout.take(state, queue, 960, 41_000)
    assert byte_size(pcm) == 960
    assert state.source_bytes == 960
    assert queue.bytes == 70 * 48
    assert state.release_reason == :queue_ready
  end

  test "prior quiet or nonquiet shortages do not accumulate into later refill targets" do
    for sample <- [0, 6_000] do
      initial = %{Playout.new(120, 9_600) | playing?: true}

      Enum.reduce(0..19, initial, fn i, state ->
        now = i * 300_000
        {_, queue, state} = Playout.take(state, %AudioQueue{}, 9_600, now)
        data = :binary.copy(<<sample::little-signed-16>>, 2_400)
        {:ok, queue} = AudioQueue.push(queue, AudioFrame.pcm(data, "history", i))
        {pcm, queue, next} = Playout.take(state, queue, 9_600, now + 60_000)
        assert pcm == data
        assert queue.bytes == 0
        assert next.source_bytes - state.source_bytes == byte_size(data)
        next
      end)
    end
  end

  test "repeated recovery stays bounded and zero buffering adds no recovery hold" do
    for {buffer, capacity} <- [{120, 9_600}, {120, 1_920}, {0, 9_600}] do
      initial = %{Playout.new(buffer, capacity) | playing?: true}

      Enum.reduce(0..30, initial, fn i, state ->
        now = i * 500_000
        empty = %AudioQueue{capacity: capacity}
        {_, queue, state} = Playout.take(state, empty, capacity, now)
        queued = append(queue, div(capacity, 48))
        {_, _, next} = Playout.take(state, queued, capacity, now + 20_000)
        assert next.source_bytes > state.source_bytes
        next
      end)
    end
  end

  test "severe-stall settling starts continuously beyond the configured cushion" do
    for {shortage, settling} <- [{120_000, 0}, {120_001, 1}, {180_000, 60_000}] do
      state = %{Playout.new(120, 9_600) | playing?: true}
      {_, queue, state} = Playout.take(state, %AudioQueue{}, 9_600, 0)
      queue = append(queue, 200)

      if settling > 0 do
        {_, held, waiting} = Playout.take(state, queue, 9_600, shortage)
        {_, held, waiting} = Playout.take(waiting, held, 9_600, shortage + settling - 1)
        assert held.bytes == 9_600
        assert waiting.source_bytes == 0
        {_, _, resumed} = Playout.take(waiting, held, 9_600, shortage + settling)
        assert resumed.source_bytes == 9_600
      else
        {_, _, resumed} = Playout.take(state, queue, 9_600, shortage)
        assert resumed.source_bytes == 9_600
      end
    end
  end

  defp append(queue, milliseconds) do
    Enum.reduce(1..div(milliseconds, 10), queue, fn i, queue ->
      frame = AudioFrame.pcm(:binary.copy(<<i, 0>>, 240), "recovery", i)
      {:ok, next} = AudioQueue.push(queue, frame)
      next
    end)
  end
end
