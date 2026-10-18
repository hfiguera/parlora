defmodule Parlora.AdaptivePlayoutTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}
  alias Parlora.Channels.{Browser, LocalAudio}
  alias Parlora.Channels.Browser.Media
  alias Parlora.Playout.Target

  defp frame(at, duration \\ 100_000, options \\ []) do
    AudioFrame.pcm(
      :binary.copy(<<1, 0>>, div(duration * 24, 1_000)),
      "source",
      0,
      Keyword.merge([clock: :local_monotonic, timestamp_us: at], options)
    )
  end

  test "receipt groups are invariant to fragmentation and local admission delay" do
    groups = [
      {-1_000_000, 100_000},
      {-900_000, 100_000},
      {-630_000, 200_000},
      {-430_000, 100_000}
    ]

    whole =
      Enum.reduce(groups, Target.new(120, 200), fn {at, duration}, s ->
        Target.observe(s, frame(at, duration), true)
      end)

    fragments =
      Enum.reduce(groups, Target.new(120, 200), fn {at, duration}, s ->
        Enum.reduce(1..div(duration, 10_000), s, fn _, s ->
          Target.observe(s, frame(at, 10_000), true)
        end)
      end)

    assert whole == fragments
    assert whole.target_ms == 190
    assert whole.increases == 1
  end

  test "large stalls clamp, quiet stable source decays slowly, and history stays bounded" do
    state = Target.new(120, 200) |> Target.observe(frame(0), false)
    state = Target.observe(state, frame(600_000), true)
    assert state.target_ms == 200

    state =
      Enum.reduce(1..400, state, fn i, s ->
        # Acoustic silence is still source audio; there is no VAD/drop shortcut.
        f = %{frame(600_000 + i * 100_000) | data: :binary.copy(<<0>>, 4_800)}
        Target.observe(s, f, false)
      end)

    assert state.target_ms >= 120
    assert state.target_ms < 200
    assert state.decreases > 0
    assert Enum.count_until(state.transits, 129) <= 128
    assert Enum.count_until(state.delays, 129) <= 128
  end

  test "reply idle, stream changes, clear and incompatible clocks restart timing" do
    state = Target.new(120, 200) |> Target.observe(frame(0), false)
    state = Target.observe(state, frame(10_000_000), true)
    assert state.target_ms == 120
    assert state.idle_resets == 1
    assert state.delays == []
    state = Target.observe(state, frame(10_270_000), true)
    assert state.target_ms == 190
    state = Target.observe(state, frame(10_370_000, 100_000, generation: 1), false)
    assert state.clock_resets == 1
    assert state.delays == []

    for f <- [
          frame(10_470_000, 100_000, clock: :provider),
          frame(10_470_000, 100_000, clock: :unknown),
          frame(10_470_000, 100_000, timestamp_us: nil)
        ] do
      assert Target.observe(state, f, true).group == nil
    end

    assert Target.reset(state).target_ms == 190
  end

  test "stable media across short replies can shrink; idle wall time cannot" do
    state = Target.new(120, 200) |> Target.observe(frame(0), false)
    state = Target.observe(state, frame(600_000), true)

    state =
      Enum.reduce(1..10, state, fn turn, state ->
        state = Target.reset(state)

        Enum.reduce(0..9, state, fn i, state ->
          Target.observe(state, frame(turn * 10_000_000 + i * 100_000), false)
        end)
      end)

    assert state.target_ms == 190
    assert state.decreases == 1
    idle = Target.observe(state, frame(9_000_000_000), true)
    assert idle.target_ms == state.target_ms
    assert idle.stable_us == state.stable_us
  end

  test "target is latched only at playback boundaries; recovery cap is independent" do
    state = Playout.new(120, 9_600, playback_buffering: :adaptive, playback_recovery_ms: 60)
    state = state |> Playout.observe(frame(0)) |> Playout.observe(frame(270_000))
    assert state.buffer_ms == 120
    assert state.target.target_ms == 190
    assert Playout.recovery_wait_us(state) == 60_000
    {:ok, queue} = AudioQueue.push(%AudioQueue{}, frame(0, 10_000))
    {_, queue, state} = Playout.take(state, queue, 480, 0)
    assert state.buffer_ms == 190
    state = Playout.observe(state, frame(870_000))
    assert state.target.target_ms == 200
    assert state.buffer_ms == 190
    {out, queue, state} = Playout.take(state, queue, 480, 190_000)
    assert out == frame(0, 10_000).data
    assert queue.bytes == 0
    {_, _, state} = Playout.take(state, queue, 480, 200_000)
    {:ok, queue} = AudioQueue.push(queue, frame(0, 10_000))
    {_, queue, state} = Playout.take(state, queue, 480, 700_000)
    assert state.buffer_ms == 200
    {out, queue, state} = Playout.take(state, queue, 480, 760_000)
    assert out == frame(0, 10_000).data
    assert queue.bytes == 0
    assert state.source_bytes == 960
    assert Playout.reset(state).target.group == nil
    {_, queue, state} = Playout.take(state, queue, 480, 800_000)
    assert Playout.wait_limit_us(state, 1_800_000) == 200_000
    assert Playout.recovery_wait_us(state) == 60_000
    {:ok, queue} = AudioQueue.push(queue, frame(0, 10_000))
    {_, queue, state} = Playout.take(state, queue, 480, 1_800_000)
    refute state.recovering?
    {out, queue, state} = Playout.take(state, queue, 480, 2_000_000)
    assert out == frame(0, 10_000).data
    assert queue.bytes == 0
    assert state.source_bytes == 1440
  end

  test "disabled buffering, queue capacity, pressure release and option validation" do
    assert Playout.new(0, 9_600, playback_buffering: :adaptive).target == nil
    assert Playout.new(20, 1_920, playback_buffering: :adaptive).target.ceiling_ms == 40
    state = %{Playout.new(120, 9_600, playback_buffering: :adaptive) | recovering?: true}
    assert Playout.release_recovery(state).playing?

    for options <- [
          [playback_buffering: :bad],
          [playback_recovery_ms: -1],
          [playback_recovery_ms: 201],
          [playback_recovery_ms: nil]
        ] do
      refute Playout.valid_options?(120, 9_600, options)
    end

    refute Playout.valid_options?(120, 1_920, [])
    assert Playout.valid_options?(120, 9_600, playback_buffering: :fixed)
  end

  test "browser learns only admitted current frames and suppression breaks timing" do
    init = %Parlora.AdapterInit{
      session_id: Parlora.ID.new(),
      adapter_id: "test",
      generation: 0,
      event_sink: self(),
      audio_format: %Parlora.AudioFormat{},
      limits: %Parlora.Limits{max_frame_bytes: 4_800}
    }

    options = %{
      jitter_ms: 0,
      max_rtp_packets: 32,
      max_age_ms: 200,
      playback_buffer_ms: 120,
      playback_buffering: :adaptive,
      playback_recovery_ms: 60
    }

    state = %{
      init: init,
      media: Media.open(init, options),
      status: :ready,
      commands: %Parlora.CommandLog{limit: 256}
    }

    on_exit(fn -> Media.close(state.media) end)
    f = %{frame(0) | playback_epoch: 0}
    {:reply, :ok, state} = Browser.handle_call({:write, f}, nil, state)
    {:reply, :ok, state} = Browser.handle_call({:write, %{f | timestamp_us: 270_000}}, nil, state)
    assert state.media.playout.target.target_ms == 190

    assert {:reply, {:error, %{code: :backpressure}}, ^state} =
             Browser.handle_call({:write, %{f | timestamp_us: 870_000}}, nil, state)

    assert {:reply, {:error, %{code: :invalid_argument}}, ^state} =
             Browser.handle_call({:write, %{f | playback_epoch: 1}}, nil, state)

    {:reply, :ok, state} =
      Browser.handle_call({:control, "suppress", {:suppress_output, true}}, nil, state)

    assert state.media.playout.target.group == nil
    {:reply, :ok, next} = Browser.handle_call({:write, f}, nil, state)
    assert next.media.playout == state.media.playout
    assert next.media.outbound.bytes == 0

    assert {:error, %{code: :invalid_argument}} =
             Browser.start_link(init, signaling: self(), playback_buffering: :bad)

    assert {:error, %{code: :invalid_argument}} =
             LocalAudio.start_link(init, device: :synthetic, playback_recovery_ms: 201)
  end
end
