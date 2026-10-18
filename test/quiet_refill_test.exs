defmodule Parlora.QuietRefillTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}

  test "low occupancy refills during quiet source, once per passage, preserving its tail" do
    state = learned()
    pcm = signal(80, 4_000) <> signal(120, 32)
    queue = queue(pcm)

    {played, queue, state} = drain(state, queue, 0..100_000//20_000)
    assert played == binary_part(pcm, 0, 120 * 48)
    before = state.source_bytes
    {silence, queue, state} = Playout.take(state, queue, 960, 120_000)
    assert silence == signal(10, 0)
    assert Playout.quiet_refill?(state)
    assert state.source_bytes == before
    assert Playout.wait_limit_us(state, 120_000) == 60_000
    {_, queue, state} = Playout.take(state, queue, 960, 179_999)
    assert state.source_bytes == before
    {tail, queue, state} = drain(state, queue, 180_000..240_000//20_000)
    assert queue.bytes == 0
    assert played <> tail == pcm
    assert state.quiet.count == 1
    refute Playout.quiet_refill?(state)
  end

  test "startup, continuous nonquiet audio, fixed mode and zero recovery do not quiet-refill" do
    for state <- [learned(), learned(:fixed), %{learned() | recovery_ms: 0}] do
      pcm = signal(200, 4_000)
      {played, queue, state} = drain(state, queue(pcm), 0..180_000//20_000)
      assert played == pcm
      assert queue.bytes == 0
      assert Playout.snapshot(state).quiet_refills == 0
    end

    state = %{learned() | playing?: false}
    pcm = signal(200, 0)
    {played, _, state} = drain(state, queue(pcm), 0..180_000//20_000)
    assert played == pcm
    assert state.quiet.count == 0
  end

  test "returning speech after quiet resumes on a complete receipt group after a brief shortage" do
    prefix = signal(20, 4_000) <> signal(20, 0) <> signal(20, 4_000)
    {_, _, state} = drain(learned(), queue(prefix), 0..40_000//20_000)
    {_, queue, state} = Playout.take(state, %AudioQueue{}, 960, 60_000)

    frame =
      AudioFrame.pcm(signal(100, 5_000), "source", 0,
        timestamp_us: 80_000,
        clock: :local_monotonic
      )

    state = Playout.observe(state, frame)
    queue = %{queue(frame.data) | capacity: queue.capacity}
    {pcm, queue, state} = Playout.take(state, queue, 960, 90_000)
    assert pcm == signal(20, 5_000)
    assert queue.bytes == 80 * 48
    assert state.release_reason == :speech_continuation
  end

  test "a small returning fragment, a severe shortage, or missing quiet history retains recovery" do
    prefix = signal(20, 4_000) <> signal(20, 0) <> signal(20, 4_000)
    {_, _, initial} = drain(learned(), queue(prefix), 0..40_000//20_000)

    for {bytes_ms, shortage, quiet} <- [
          {60, 30_000, initial.quiet},
          {100, 90_000, initial.quiet},
          {100, 30_000, %{initial.quiet | last_quiet_byte: nil}}
        ] do
      state = %{initial | quiet: quiet}
      {_, queue, state} = Playout.take(state, %AudioQueue{}, 960, 60_000)

      frame =
        AudioFrame.pcm(signal(bytes_ms, 4_000), "source", 0,
          timestamp_us: 70_000,
          clock: :local_monotonic
        )

      state = Playout.observe(state, frame)
      queue = %{queue(frame.data) | capacity: queue.capacity}
      before = state.source_bytes
      {_, queue, state} = Playout.take(state, queue, 960, 60_000 + shortage)
      assert state.source_bytes == before
      assert queue.bytes == bytes_ms * 48
    end
  end

  test "pressure drains a quiet hold and clear or discontinuity resets its evidence" do
    {_, queue, state} =
      drain(learned(), queue(signal(80, 4_000) <> signal(120, 0)), 0..100_000//20_000)

    {_, queue, state} = Playout.take(state, queue, 960, 120_000)
    assert Playout.quiet_refill?(state)
    released = Playout.release_recovery(state)
    refute Playout.quiet_refill?(released)
    {pcm, _, _} = Playout.take(released, queue, 960, 130_000)
    assert byte_size(pcm) == 960

    cleared = Playout.reset(state)
    refute Playout.quiet_refill?(cleared)
    assert cleared.quiet.last_quiet_byte == nil
    refute cleared.quiet.seen_nonquiet?

    frame =
      AudioFrame.pcm(signal(20, 0), "new", 0,
        timestamp_us: 140_000,
        clock: :local_monotonic,
        discontinuity: true
      )

    reset = Playout.observe(state, frame)
    refute Playout.quiet_refill?(reset)
    assert reset.quiet.last_quiet_byte == nil
    assert reset.playing?
  end

  test "a refilled cushion releases before the quiet deadline and short recovery caps are respected" do
    for cap <- [20, 120] do
      initial = %{learned() | recovery_ms: cap}

      {_, queue, state} =
        drain(initial, queue(signal(80, 4_000) <> signal(120, 0)), 0..100_000//20_000)

      {_, queue, state} = Playout.take(state, queue, 960, 120_000)
      assert Playout.wait_limit_us(state, 120_000) == min(cap, 60) * 1_000
      extra = queue(signal(120, 4_000)).items |> :queue.to_list()

      queue =
        Enum.reduce(extra, queue, fn frame, acc ->
          {:ok, acc} = AudioQueue.push(acc, frame)
          acc
        end)

      before = state.source_bytes
      {pcm, _, state} = Playout.take(state, queue, 960, 130_000)
      assert pcm == signal(20, 0)
      assert state.source_bytes == before + 960
      assert state.release_reason == :quiet_refill
      refute Playout.quiet_refill?(state)
    end
  end

  test "unknown clocks cannot trigger quiet refills, even with a previously learned target" do
    frame = AudioFrame.pcm(signal(20, 0), "source", 0)
    state = Playout.observe(learned(), frame)
    assert state.target.group == nil
    pcm = signal(80, 4_000) <> signal(120, 0)
    {played, _, state} = drain(state, queue(pcm), 0..180_000//20_000)
    assert played == pcm
    assert state.quiet.count == 0
  end

  defp learned(mode \\ :adaptive) do
    state = %{Playout.new(120, 9_600, playback_buffering: mode) | playing?: true, buffer_ms: 200}

    if state.target,
      do: %{
        state
        | target: %{
            state.target
            | target_ms: 200,
              group: %{at: 0, duration: 20_000, identity: {"source", 0}}
          }
      },
      else: state
  end

  defp signal(ms, sample), do: :binary.copy(<<sample::little-signed-16>>, ms * 24)

  defp queue(pcm) do
    for <<part::binary-size(480) <- pcm>>, reduce: %AudioQueue{} do
      queue ->
        {:ok, queue} = AudioQueue.push(queue, AudioFrame.pcm(part, "source", 0))
        queue
    end
  end

  defp drain(state, queue, times) do
    Enum.reduce(times, {<<>>, queue, state}, fn at, {output, queue, state} ->
      before = state.source_bytes
      {pcm, queue, state} = Playout.take(state, queue, 960, at)
      assert state.source_bytes > before
      {output <> pcm, queue, state}
    end)
  end
end
