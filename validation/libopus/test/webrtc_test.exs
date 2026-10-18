defmodule OpusWebRTCTest do
  use ExUnit.Case
  alias ExWebRTC.{MediaStreamTrack, PeerConnection}

  defp stereo_packets do
    parse_packets(File.read!(Path.join(__DIR__, "fixtures/stereo-opus.bin")))
  end

  defp parse_packets(<<>>), do: []

  defp parse_packets(<<size::32, data::binary-size(size), rest::binary>>) do
    [%{data: data} | parse_packets(rest)]
  end

  defp encode(rate, channels) do
    {:ok, encoder} = OpusProbe.new(:encoder, rate, channels, 2048)

    samples = div(rate, 50)

    packets =
      Enum.flat_map(0..19, fn frame_index ->
        pcm =
          for i <- 0..(samples - 1), channel <- 1..channels, into: <<>> do
            value =
              round(
                8_000 *
                  :math.sin(
                    2 * :math.pi() * (350 + channel * 90) *
                      (frame_index * samples + i) / rate
                  )
              )

            <<value::signed-little-16>>
          end

        {:ok, packet} = OpusProbe.encode(encoder, pcm, samples)
        [%{data: packet}]
      end)

    assert length(packets) == 20
    :ok = OpusProbe.close(encoder)
    packets
  end

  defp decode(packets, rate, channels) do
    {:ok, decoder} = OpusProbe.new(:decoder, rate, channels, 2048)

    frames =
      Enum.map(packets, fn packet ->
        {:ok, pcm, samples} = OpusProbe.decode(decoder, packet.data, div(rate, 50), 0)
        %{type: :audio, format: :s16, data: pcm, samples: samples}
      end)

    :ok = OpusProbe.close(decoder)

    assert length(frames) >= 19

    assert Enum.all?(frames, fn frame ->
             frame.type == :audio and frame.format == :s16 and
               byte_size(frame.data) == frame.samples * 2 * channels
           end)

    total = Enum.sum(Enum.map(frames, & &1.samples))
    assert total >= round(rate * 0.37)
    assert total <= round(rate * 0.41)

    assert Enum.any?(frames, fn frame ->
             Enum.any?(
               for(<<sample::signed-little-16 <- frame.data>>, do: sample),
               &(abs(&1) > 500)
             )
           end)
  end

  test "Opus stereo 48 kHz to mono PCM16 24 kHz and reverse" do
    decode(stereo_packets(), 24_000, 1)
    decode(encode(24_000, 1), 48_000, 2)
  end

  test "negotiated WebRTC transports libopus payloads in both directions" do
    {:ok, a} = PeerConnection.start_link()
    {:ok, b} = PeerConnection.start_link()
    track_a = MediaStreamTrack.new(:audio)
    track_b = MediaStreamTrack.new(:audio)
    {:ok, _} = PeerConnection.add_track(a, track_a)
    {:ok, _} = PeerConnection.add_track(b, track_b)
    {:ok, offer} = PeerConnection.create_offer(a)
    assert offer.sdp =~ "opus/48000/2"
    :ok = PeerConnection.set_local_description(a, offer)
    :ok = PeerConnection.set_remote_description(b, offer)
    {:ok, answer} = PeerConnection.create_answer(b)
    :ok = PeerConnection.set_local_description(b, answer)
    :ok = PeerConnection.set_remote_description(a, answer)
    deadline = System.monotonic_time(:millisecond) + 15_000
    connect(a, b, MapSet.new(), deadline)
    packets_a = stereo_packets()
    packets_b = encode(24_000, 1)

    Enum.zip(packets_a, packets_b)
    |> Enum.with_index()
    |> Enum.each(fn {{pa, pb}, i} ->
      :ok =
        PeerConnection.send_rtp(
          a,
          track_a.id,
          ExRTP.Packet.new(pa.data, sequence_number: i, timestamp: i * 960)
        )

      :ok =
        PeerConnection.send_rtp(
          b,
          track_b.id,
          ExRTP.Packet.new(pb.data, sequence_number: i, timestamp: i * 960)
        )

      Process.sleep(20)
    end)

    received =
      receive_rtp(
        a,
        b,
        %{a => [], b => []},
        length(packets_a) * 2,
        System.monotonic_time(:millisecond) + 5_000
      )

    for {receiver, expected, rate, channels} <- [
          {a, packets_b, 48_000, 2},
          {b, packets_a, 24_000, 1}
        ] do
      actual = received[receiver] |> Enum.sort_by(& &1.sequence_number)
      assert Enum.map(actual, & &1.payload) == Enum.map(expected, & &1.data)
      assert Enum.map(actual, & &1.timestamp) == Enum.map(0..(length(expected) - 1), &(&1 * 960))
      decode(Enum.map(actual, &%{data: &1.payload}), rate, channels)
    end

    :ok = PeerConnection.close(a)
    :ok = PeerConnection.close(b)
  end

  defp connect(a, b, connected, deadline) do
    if MapSet.size(connected) < 2 do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:ex_webrtc, pc, {:ice_candidate, candidate}} ->
          :ok = PeerConnection.add_ice_candidate(if(pc == a, do: b, else: a), candidate)
          connect(a, b, connected, deadline)

        {:ex_webrtc, pc, {:connection_state_change, :connected}} ->
          connect(a, b, MapSet.put(connected, pc), deadline)

        {:ex_webrtc, _, {:connection_state_change, :failed}} ->
          flunk("WebRTC failed")

        _ ->
          connect(a, b, connected, deadline)
      after
        remaining -> flunk("WebRTC connection timed out")
      end
    end
  end

  defp receive_rtp(_a, _b, received, 0, _deadline), do: received

  defp receive_rtp(a, b, received, count, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ex_webrtc, pc, {:rtp, _, _, packet}} when pc == a or pc == b ->
        receive_rtp(a, b, Map.update!(received, pc, &[packet | &1]), count - 1, deadline)

      _ ->
        receive_rtp(a, b, received, count, deadline)
    after
      remaining -> flunk("Missing #{count} RTP packets")
    end
  end
end
