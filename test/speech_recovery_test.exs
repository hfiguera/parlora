defmodule Parlora.SpeechRecoveryTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}

  test "recorded mid-speech stalls resume earlier without additional speech gaps or sample loss" do
    fixture =
      File.read!("test/fixtures/gpt-live-speech-recovery-20261004.json") |> JSON.decode!()

    for report <- fixture["reports"], phase <- 0..9_000//1_000 do
      result = replay(report, phase)
      assert [gap] = result.gaps
      assert gap < report["recorded_gap_us"] - 60_000
      assert gap <= report["recorded_shortage_us"] + 31_000
      assert result.peak_bytes <= 9_600
      assert result.pending == []
      assert result.received == result.played
    end
  end

  test "established speech needs a complete substantial receipt and a bounded settling interval" do
    for duration <- [80, 100, 120], shortage <- [50_000, 90_000, 110_000] do
      state = speech_state()
      {_, empty, state} = Playout.take(state, %AudioQueue{}, 960, 0)
      {queue, state} = admit(empty, state, duration, 6_000, shortage)
      {_, queue, held} = Playout.take(state, queue, 960, shortage)
      assert held.source_bytes == 16_320
      {_, queue, held} = Playout.take(held, queue, 960, shortage + 19_999)
      assert held.source_bytes == 16_320
      {pcm, _, resumed} = Playout.take(held, queue, 960, shortage + 20_000)
      assert byte_size(pcm) == 960
      assert resumed.source_bytes == 17_280
      assert resumed.release_reason == :speech_continuation
    end
  end

  test "small fragments, quiet tails, severe stalls and missing speech history keep full recovery" do
    for {duration, sample, shortage, seen} <- [
          {60, 6_000, 90_000, true},
          {100, 0, 90_000, true},
          {100, 6_000, 180_000, true},
          {100, 6_000, 90_000, false}
        ] do
      state = speech_state()
      state = %{state | quiet: %{state.quiet | seen_nonquiet?: seen}}
      {_, empty, state} = Playout.take(state, %AudioQueue{}, 960, 0)
      {queue, state} = admit(empty, state, duration, sample, shortage)
      {_, queue, state} = Playout.take(state, queue, 960, shortage)
      {_, held, state} = Playout.take(state, queue, 960, shortage + 20_000)
      assert state.source_bytes == 16_320
      assert held.bytes == duration * 48
    end
  end

  test "clear removes speech evidence and zero recovery remains immediate" do
    state = %{speech_state() | speech_recovery_debt_us: 90_000} |> Playout.reset()
    refute state.quiet.seen_nonquiet?
    assert state.speech_recovery_debt_us == 0
    state = %{speech_state() | recovery_ms: 0}
    {_, empty, state} = Playout.take(state, %AudioQueue{}, 960, 0)
    {queue, state} = admit(empty, state, 100, 6_000, 90_000)
    {_, _, state} = Playout.take(state, queue, 960, 90_000)
    assert state.source_bytes == 17_280
    assert state.release_reason == :buffering_disabled
  end

  test "another shortage keeps full recovery even if a receipt momentarily fills the queue" do
    state = speech_state()
    {_, empty, state} = Playout.take(state, %AudioQueue{}, 960, 0)
    {queue, state} = admit(empty, state, 100, 6_000, 90_000)
    {_, queue, state} = Playout.take(state, queue, 960, 90_000)
    {_, queue, state} = Playout.take(state, queue, 960, 110_000)
    assert state.speech_recovery_debt_us == 90_000

    {queue, state} =
      Enum.reduce(130_000..190_000//20_000, {queue, state}, fn at, {queue, state} ->
        {_, queue, state} = Playout.take(state, queue, 960, at)
        {queue, state}
      end)

    assert queue.bytes == 0
    {_, empty, state} = Playout.take(state, queue, 960, 210_000)
    {queue, state} = admit(empty, state, 100, 6_000, 300_000)
    before = state.source_bytes
    {_, queue, state} = Playout.take(state, queue, 960, 300_000)
    {_, queue, state} = Playout.take(state, queue, 960, 320_000)
    assert state.source_bytes == before
    {queue, state} = admit(queue, state, 100, 6_000, 390_000)
    {_, _, state} = Playout.take(state, queue, 960, 390_000)
    assert state.source_bytes > before
    assert state.speech_recovery_debt_us == 90_000
  end

  test "quiet restoration repays saved time before another selective speech restart" do
    state = speech_state()
    {_, empty, state} = Playout.take(state, %AudioQueue{}, 960, 0)
    {queue, state} = admit(empty, state, 100, 6_000, 90_000)
    {_, queue, state} = Playout.take(state, queue, 960, 90_000)
    {_, queue, state} = Playout.take(state, queue, 960, 110_000)
    {queue, state} = drain_speech(queue, state)
    {queue, state} = admit(queue, state, 80, 0, 200_000)
    {_, queue, state} = Playout.take(state, queue, 960, 210_000)
    before = state.source_bytes
    {_, queue, state} = Playout.take(state, queue, 960, 230_000)
    assert Playout.wait_limit_us(state, 230_000) == 150_000
    {_, queue, state} = Playout.take(state, queue, 960, 290_000)
    {queue, state} = admit(queue, state, 100, 6_000, 300_000)
    {queue, state} = admit(queue, state, 40, 6_000, 370_000)
    assert queue.bytes == 9_600
    {_, queue, state} = Playout.take(state, queue, 960, 379_999)
    assert state.source_bytes == before
    {_, _, state} = Playout.take(state, queue, 960, 380_000)
    assert state.source_bytes == before + 960
    assert state.release_reason == :quiet_refill
    assert state.speech_recovery_debt_us == 0
  end

  test "pressure can release a quiet restoration without forgetting unpaid reserve" do
    state = %{
      speech_state()
      | speech_recovery_debt_us: 90_000,
        recovering?: true,
        playing?: false,
        quiet: %{speech_state().quiet | refilling?: true}
    }

    state = Playout.release_recovery(state)
    assert state.playing?
    refute state.recovering?
    assert state.release_reason == :pressure
    assert state.speech_recovery_debt_us == 90_000
  end

  test "a restoration-only quiet hold repays reserve without adding the ordinary 60 ms wait" do
    initial = speech_state()

    initial = %{
      initial
      | speech_recovery_debt_us: 90_000,
        quiet: %{initial.quiet | quiet_us: 20_000}
    }

    {queue, state} = admit(%AudioQueue{}, initial, 140, 0, 0)
    {_, queue, state} = Playout.take(state, queue, 960, 0)
    assert Playout.wait_limit_us(state, 0) == 90_000
    {_, queue, state} = Playout.take(state, queue, 960, 89_999)
    assert state.source_bytes == 16_320
    {_, _, state} = Playout.take(state, queue, 960, 90_000)
    assert state.source_bytes == 17_280
    assert state.speech_recovery_debt_us == 0
  end

  test "an early full cushion starts repayment at readiness rather than the ordinary deadline" do
    initial = speech_state()

    initial = %{
      initial
      | speech_recovery_debt_us: 90_000,
        quiet: %{initial.quiet | quiet_us: 20_000}
    }

    {queue, state} = admit(%AudioQueue{}, initial, 80, 0, 0)
    {_, queue, state} = Playout.take(state, queue, 960, 0)
    {queue, state} = admit(queue, state, 120, 0, 20_000)
    {_, queue, state} = Playout.take(state, queue, 960, 20_000)
    assert state.quiet_restore_since_us == 20_000
    assert Playout.wait_limit_us(state, 20_000) == 110_000
    {_, queue, state} = Playout.take(state, queue, 960, 109_999)
    assert state.source_bytes == 16_320
    {_, _, state} = Playout.take(state, queue, 960, 110_000)
    assert state.source_bytes == 17_280
    assert state.speech_recovery_debt_us == 0
  end

  test "missing or stale quiet evidence and unknown receipt clocks cannot enable early speech" do
    for last_quiet <- [nil, -48_001] do
      state = speech_state()
      state = %{state | quiet: %{state.quiet | last_quiet_byte: last_quiet}}
      {_, empty, state} = Playout.take(state, %AudioQueue{}, 960, 0)
      {queue, state} = admit(empty, state, 100, 6_000, 90_000)
      {_, queue, state} = Playout.take(state, queue, 960, 90_000)
      {_, _, state} = Playout.take(state, queue, 960, 110_000)
      assert state.source_bytes == 16_320
    end

    state = %{speech_state() | speech_recovery_debt_us: 90_000}
    frame = AudioFrame.pcm(:binary.copy(<<6_000::little-signed-16>>, 2_400), "speech", 0)
    state = Playout.observe(state, frame)
    assert state.target.group == nil
    assert state.speech_recovery_debt_us == 0
    refute state.quiet.seen_nonquiet?
  end

  test "an idle receipt boundary clears reserve accounting and requires new speech evidence" do
    {_, state} = admit(%AudioQueue{}, speech_state(), 100, 6_000, 0)
    state = %{state | speech_recovery_debt_us: 90_000}
    {_, state} = admit(%AudioQueue{}, state, 100, 6_000, 1_100_000)
    assert state.speech_recovery_debt_us == 0
    refute state.quiet.seen_nonquiet?
  end

  test "time without source cannot repay a quiet restoration" do
    initial = speech_state()

    initial = %{
      initial
      | playing?: false,
        recovering?: true,
        waiting_since_us: 0,
        speech_recovery_debt_us: 90_000,
        quiet_restore_since_us: 0,
        quiet: %{initial.quiet | refilling?: true, quiet_us: 20_000}
    }

    {_, queue, state} = Playout.take(initial, %AudioQueue{}, 960, 100_000)
    assert state.quiet_restore_since_us == nil
    {queue, state} = admit(queue, state, 140, 0, 200_000)
    {_, _, state} = Playout.take(state, queue, 960, 200_000)
    assert state.speech_recovery_debt_us == 90_000
    assert state.source_bytes == initial.source_bytes
  end

  defp drain_speech(queue, state) do
    Enum.reduce(130_000..190_000//20_000, {queue, state}, fn at, {queue, state} ->
      {_, queue, state} = Playout.take(state, queue, 960, at)
      {queue, state}
    end)
  end

  defp speech_state do
    state = %{Playout.new(120, 9_600, playback_buffering: :adaptive) | playing?: true}

    %{
      state
      | target: %{state.target | target_ms: 200},
        quiet: %{state.quiet | seen_nonquiet?: true, last_quiet_byte: 0},
        source_bytes: 16_320
    }
  end

  defp admit(queue, state, duration, sample, at) do
    Enum.reduce(0..(div(duration, 10) - 1), {queue, state}, fn sequence, {queue, state} ->
      frame =
        AudioFrame.pcm(:binary.copy(<<sample::little-signed-16>>, 240), "speech", sequence,
          timestamp_us: at,
          clock: :local_monotonic
        )

      {:ok, queue} = AudioQueue.push(queue, frame)
      {queue, Playout.observe(state, frame)}
    end)
  end

  defp replay(report, phase) do
    events =
      Enum.map(report["arrivals"], fn [at, peaks] -> {at, :arrival, peaks} end) ++
        Enum.map(report["renders"], &{&1 + phase, :render, nil})

    initial = %{
      playout: speech_state(),
      queue: %AudioQueue{},
      pending: [],
      staged: <<>>,
      received: <<>>,
      played: <<>>,
      gaps: [],
      open_gap: nil,
      last_nonquiet?: true,
      peak_bytes: 0,
      sequence: 0
    }

    result = Enum.reduce(Enum.sort_by(events, &elem(&1, 0)), initial, &step/2)
    # Drain the entire tail so a shorter gap cannot conceal dropped or reordered samples.
    Enum.reduce(1..100, result, fn i, state ->
      step({List.last(report["renders"]) + i * 10_000, :render, nil}, state)
    end)
  end

  defp step({at, :arrival, peaks}, state) do
    {frames, sequence} =
      Enum.map_reduce(peaks, state.sequence, fn peak, sequence ->
        # The report contains packet peaks, not PCM. These constant-amplitude proxies
        # reproduce quiet/nonquiet classification; equality verifies our synthetic samples.
        frame =
          AudioFrame.pcm(:binary.copy(<<peak::little-signed-16>>, 240), "speech", sequence,
            timestamp_us: at,
            clock: :local_monotonic
          )

        {frame, sequence + 1}
      end)

    %{
      state
      | pending: state.pending ++ frames,
        sequence: sequence,
        received: state.received <> Enum.map_join(frames, & &1.data)
    }
    |> transfer()
  end

  defp step({at, :render, _}, state) do
    state = transfer(state)

    {pcm, queue, playout, source?} =
      if state.staged == <<>> do
        {pcm, queue, playout} = Playout.take(state.playout, state.queue, 960, at)
        {pcm, queue, playout, playout.source_bytes > state.playout.source_bytes}
      else
        {state.staged, state.queue, state.playout, true}
      end

    <<packet::binary-size(480), rest::binary>> = pcm
    nonquiet? = Enum.any?(for(<<sample::little-signed-16 <- packet>>, do: abs(sample) > 64))

    {gaps, open} = render_gap(state, source?, nonquiet?, at)

    %{
      state
      | queue: queue,
        playout: playout,
        staged: rest,
        played: if(source?, do: state.played <> packet, else: state.played),
        gaps: gaps,
        open_gap: open,
        last_nonquiet?: if(source?, do: nonquiet?, else: state.last_nonquiet?)
    }
    |> transfer()
  end

  defp render_gap(state, source?, nonquiet?, at) do
    cond do
      source? and nonquiet? and state.open_gap != nil ->
        {state.gaps ++ [at - state.open_gap], nil}

      source? ->
        {state.gaps, nil}

      state.open_gap == nil and state.last_nonquiet? ->
        {state.gaps, at}

      true ->
        {state.gaps, state.open_gap}
    end
  end

  defp transfer(%{pending: [frame | rest]} = state) do
    case AudioQueue.push(state.queue, frame) do
      {:ok, queue} ->
        transfer(%{
          state
          | queue: queue,
            pending: rest,
            playout: Playout.observe(state.playout, frame),
            peak_bytes: max(state.peak_bytes, queue.bytes)
        })

      {:error, _} ->
        state
    end
  end

  defp transfer(state), do: state
end
