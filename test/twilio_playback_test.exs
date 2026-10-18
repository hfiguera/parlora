defmodule Parlora.TwilioPlaybackTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, AudioFrame}
  alias Parlora.Channels.MediaStream.Playback

  test "marks after clear remain ambiguous, and a fresh barrier allows new playback" do
    frame = AudioFrame.new(<<255>>, AudioFormat.pcmu(), "voice", 0, playback_epoch: 0)
    {:ok, first, pending} = Playback.admit(%Playback{capacity: 1}, frame, 0)
    assert {:error, %{code: :backpressure}} = Playback.admit(pending, frame, 1)
    {:ok, barrier, clearing} = Playback.clear(pending, "clear", 1, 2)
    assert {:error, %{code: :backpressure}} = Playback.admit(clearing, frame, 3)
    assert {:error, %{code: :backpressure}} = Playback.clear(clearing, "other", 2, 3)

    assert {:playback, %{stage: :unknown, cause: :clear_race}, clearing} =
             Playback.acknowledge(clearing, first)

    assert {:unknown, ^clearing} = Playback.acknowledge(clearing, first)

    assert {:clear, %{command_id: "clear", epoch: 1}, empty} =
             Playback.acknowledge(clearing, barrier)

    assert empty.bytes == 0
    assert empty.pending == %{}
    {:ok, second, pending} = Playback.admit(empty, %{frame | playback_epoch: 1}, 4)
    assert second != first

    assert {:playback, %{stage: :device_reported_playback, epoch: 1}, _empty} =
             Playback.acknowledge(pending, second)
  end

  test "missing marks reach a finite deadline even after clear" do
    frame = AudioFrame.new(<<255>>, AudioFormat.pcmu(), "voice", 0)
    {:ok, _mark, pending} = Playback.admit(%Playback{}, frame, 100)
    refute Playback.expired?(pending, 1_000_099, 1_000)
    assert Playback.expired?(pending, 1_000_100, 1_000)
    {:ok, _mark, clearing} = Playback.clear(pending, "clear", 1, 500)
    assert Playback.expired?(clearing, 1_000_100, 1_000)
  end
end
