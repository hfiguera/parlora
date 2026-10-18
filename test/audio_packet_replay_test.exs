defmodule Parlora.AudioPacketReplayTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}
  alias Parlora.TestSupport.AudioBenchmark.Packet

  test "fragments fill packets without per-fragment padding, retaining the right source age" do
    {:ok, queue} =
      AudioQueue.push(%AudioQueue{}, AudioFrame.pcm(<<7, 0>>, "fragment", 0, timestamp_us: 3_000))

    pcm = :binary.copy(<<8, 0>>, 240)
    {:ok, queue} = AudioQueue.push(queue, AudioFrame.pcm(pcm, "fragment", 1, timestamp_us: 5_000))

    {rendered, source, age, queue, playout, buffer} =
      Packet.take(%Packet{}, queue, Playout.new(0, 9_600), Playout, 960, 10_000)

    assert source == <<7, 0>> <> binary_part(pcm, 0, 478)
    assert rendered == source
    assert age == 7_000
    assert buffer.pcm == <<8, 0>>

    {rendered, source, age, queue, _playout, buffer} =
      Packet.take(buffer, queue, playout, Playout, 960, 20_000)

    assert source == <<8, 0>>
    assert rendered == <<8, 0>> <> :binary.copy(<<0>>, 478)
    assert age == 15_000
    assert buffer.pcm == <<>>
    assert buffer.segments == []
    assert queue.bytes == 0
  end
end
