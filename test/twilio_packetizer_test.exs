defmodule Parlora.TwilioPacketizerTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, AudioFrame, AudioQueue}
  alias Parlora.Channels.MediaStream.Packetizer

  test "two 10 ms provider chunks become one byte-preserving 20 ms wire packet" do
    queue = queue([:binary.copy(<<42>>, 80), :binary.copy(<<128>>, 80)])
    assert {:ready, frame, rest} = Packetizer.take(queue, 0)
    assert frame.data == :binary.copy(<<42>>, 80) <> :binary.copy(<<128>>, 80)
    assert frame.duration_us == 20_000
    assert rest.bytes == 0
    assert :empty = Packetizer.take(rest, 0)
  end

  test "unaligned chunks retain every byte and flush a short tail within 20 ms" do
    data = :binary.list_to_bin(Enum.to_list(0..200))
    <<a::binary-size(79), b::binary-size(83), c::binary>> = data
    queue = queue([a, b, c])
    assert {:ready, packet, remaining} = Packetizer.take(queue, 0)
    assert byte_size(packet.data) == 160
    assert remaining.bytes == 41
    assert {:wait, 20} = Packetizer.take(remaining, 0)
    assert {:ready, tail, empty} = Packetizer.take(remaining, 20_000)
    assert tail.duration_us == 5_125
    assert packet.data <> tail.data == data
    assert empty.bytes == 0
    assert packet.playback_epoch == tail.playback_epoch
  end

  defp queue(parts) do
    parts
    |> Stream.with_index()
    |> Enum.reduce(%AudioQueue{}, fn {data, index}, queue ->
      frame =
        AudioFrame.new(data, AudioFormat.pcmu(), "provider", index,
          timestamp_us: 0,
          playback_epoch: 3
        )

      {:ok, next} = AudioQueue.push(queue, frame)
      next
    end)
  end
end
