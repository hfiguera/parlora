defmodule Parlora.BrowserJitterTest do
  use ExUnit.Case, async: true
  alias Parlora.Channels.Browser.JitterBuffer

  test "long DTX silence is valid but unrecoverable timeline jumps fail explicitly" do
    {:ok, buffer} = JitterBuffer.put(%JitterBuffer{}, packet(0, 0), 480, 0)
    {:decode, _, _, _, buffer} = JitterBuffer.take(buffer, 40_000)
    assert {:ok, next} = JitterBuffer.put(buffer, packet(1, 960_000), 480, 20_000_000)
    assert {:wait, ^next} = JitterBuffer.take(next, 20_000_000)
    assert {:decode, _, _, false, _} = JitterBuffer.take(next, 20_040_000)

    assert {:error, :rtp_timeline_jump} =
             JitterBuffer.put(buffer, packet(1000, 960_000), 480, 20_000_000)

    assert {:error, :rtp_timeline_jump} =
             JitterBuffer.put(buffer, packet(1, 960_000), 480, 50_000)
  end

  defp packet(sequence, timestamp, payload \\ <<1>>),
    do: ExRTP.Packet.new(payload, sequence_number: sequence, timestamp: timestamp, ssrc: 123)

  test "reordering, duplicate rejection, both RTP wraps, and playout deadline" do
    {:ok, buffer} = JitterBuffer.put(%JitterBuffer{}, packet(65_535, 4_294_966_336), 480, 0)
    {:ok, buffer} = JitterBuffer.put(buffer, packet(1, 960), 480, 10_000)
    {:ok, buffer} = JitterBuffer.put(buffer, packet(0, 0), 480, 20_000)

    assert {:drop, :duplicate_packet, ^buffer} =
             JitterBuffer.put(buffer, packet(0, 0), 480, 30_000)

    assert {:wait, ^buffer} = JitterBuffer.take(buffer, 39_999)
    assert {:decode, _, 480, false, buffer} = JitterBuffer.take(buffer, 40_000)
    assert {:decode, _, 480, false, buffer} = JitterBuffer.take(buffer, 60_000)
    assert {:decode, _, 480, false, buffer} = JitterBuffer.take(buffer, 80_000)
    assert {:drop, :late_packet, ^buffer} = JitterBuffer.put(buffer, packet(0, 0), 480, 90_000)
  end

  test "one missing 20 ms frame requests FEC then decodes the same following packet" do
    {:ok, buffer} = JitterBuffer.put(%JitterBuffer{}, packet(0, 0), 480, 0)
    {:ok, buffer} = JitterBuffer.put(buffer, packet(2, 1920, <<3>>), 480, 40_000)
    {:decode, _, _, false, buffer} = JitterBuffer.take(buffer, 40_000)
    assert {:decode, <<3>>, 480, true, buffer} = JitterBuffer.take(buffer, 60_000)
    assert {:decode, <<3>>, 480, false, _buffer} = JitterBuffer.take(buffer, 80_000)
  end

  test "DTX timestamp gap with consecutive sequence numbers waits without inventing loss" do
    {:ok, buffer} = JitterBuffer.put(%JitterBuffer{}, packet(0, 0), 480, 0)
    {:decode, _, _, _, buffer} = JitterBuffer.take(buffer, 40_000)
    {:ok, buffer} = JitterBuffer.put(buffer, packet(1, 4800), 480, 100_000)
    assert {:wait, ^buffer} = JitterBuffer.take(buffer, 60_000)
    assert {:decode, _, _, false, _buffer} = JitterBuffer.take(buffer, 140_000)
  end

  test "packet and age bounds discard explicitly, and SSRC changes are rejected" do
    {:ok, buffer} = JitterBuffer.put(%JitterBuffer{max_packets: 2}, packet(0, 0), 480, 0)

    assert {:drop, :unexpected_ssrc, ^buffer} =
             JitterBuffer.put(buffer, %{packet(1, 960) | ssrc: 456}, 480, 0)

    {:ok, buffer} = JitterBuffer.put(buffer, packet(1, 960), 480, 0)
    assert {:drop, :rtp_overflow, ^buffer} = JitterBuffer.put(buffer, packet(2, 1920), 480, 0)
    assert {:drop, :late_packet, buffer} = JitterBuffer.take(buffer, 250_000)
    assert buffer.expected == 1
    assert map_size(buffer.packets) == 1
  end
end
