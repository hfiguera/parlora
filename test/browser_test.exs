defmodule Parlora.BrowserTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias ExWebRTC.PeerConnection
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Event, Limits}
  alias Parlora.Channels.Browser
  alias Parlora.Native.Opus
  alias Parlora.TestSupport.BrowserPeer

  defp connect do
    init = %AdapterInit{
      session_id: "browser-test",
      adapter_id: "browser",
      generation: 0,
      audio_format: %AudioFormat{},
      event_sink: self(),
      limits: %Limits{}
    }

    {:ok, channel} = Browser.start_link(init, signaling: self())
    assert_receive {:parlora_browser, ^channel, :attached}, 5_000
    {pc, track} = BrowserPeer.connect(channel)
    assert_receive {:parlora_event, %Event{source: :channel, type: :ready}}

    on_exit(fn ->
      Browser.close(channel, "cleanup", :test)
      if Process.alive?(channel), do: GenServer.stop(channel)
      if Process.alive?(pc), do: GenServer.stop(pc)
    end)

    {channel, pc, track}
  end

  test "encrypted bidirectional media, controls, and native/peer cleanup" do
    {channel, pc, track} = connect()
    {:ok, encoder} = Opus.new(:encoder, 48_000, 2, 2048)
    {:ok, decoder} = Opus.new(:decoder, 48_000, 2, 2048)

    tone =
      for i <- 0..479,
          into: <<>>,
          do: <<round(8_000 * :math.sin(i / 24_000 * 440 * 2 * :math.pi()))::signed-little-16>>

    stereo =
      for i <- 0..959,
          _channel <- 1..2,
          into: <<>>,
          do: <<round(8_000 * :math.sin(i / 48_000 * 440 * 2 * :math.pi()))::signed-little-16>>

    pcm =
      Enum.map_join(0..7, fn index ->
        {:ok, packet} = Opus.encode(encoder, stereo, 960)

        :ok =
          PeerConnection.send_rtp(
            pc,
            track.id,
            ExRTP.Packet.new(packet, sequence_number: index, timestamp: index * 960)
          )

        :ok =
          Browser.write_audio(channel, AudioFrame.pcm(tone, "output", index, playback_epoch: 0))

        Process.sleep(20)
        {:ok, frames} = Browser.read_audio(channel, 9_600)
        Enum.map_join(frames, & &1.data)
      end)

    assert peak(pcm) > 500
    received = receive_audio(pc, decoder, 30, [])
    assert Enum.any?(received, &(peak(&1) > 500))
    assert :ok = Browser.control(channel, "clear", {:clear_output, 1})
    assert :ok = Browser.control(channel, "clear", {:clear_output, 1})
    assert {:error, _} = Browser.control(channel, "clear", {:clear_output, 2})

    assert {:error, _} =
             Browser.write_audio(channel, AudioFrame.pcm(tone, "old", 0, playback_epoch: 0))

    assert :ok = Browser.control(channel, "stop", {:suppress_output, true})

    assert :ok =
             Browser.write_audio(
               channel,
               AudioFrame.pcm(tone, "suppressed", 42, playback_epoch: 1)
             )

    assert Browser.observations(channel).output_bytes == 0

    refute_receive {:parlora_event,
                    %Event{type: :playback_observed, payload: %{stage: :queued, sequence: 42}}}

    assert :ok = Browser.control(channel, "resume", {:suppress_output, false})
    state = :sys.get_state(channel)
    monitor = Process.monitor(state.pc)
    assert :ok = Browser.close(channel, "close", :test)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    assert {:error, :closed_or_wrong_kind} = Opus.reset(state.media.encoder)
    assert {:error, :closed_or_wrong_kind} = Opus.reset(state.media.decoder)
    Opus.close(encoder)
    Opus.close(decoder)
  end

  defp receive_audio(_pc, _decoder, 0, audio), do: audio

  defp receive_audio(pc, decoder, remaining, audio) do
    receive do
      {:ex_webrtc, ^pc, {:rtp, _track, nil, packet}} ->
        {:ok, pcm, _count} = Opus.decode(decoder, packet.payload, 5760, 0)
        receive_audio(pc, decoder, remaining - 1, [pcm | audio])
    after
      2_000 -> flunk("No outbound RTP")
    end
  end

  defp peak(pcm),
    do: for(<<sample::signed-little-16 <- pcm>>, reduce: 0, do: (acc -> max(acc, abs(sample))))
end
