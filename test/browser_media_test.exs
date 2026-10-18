defmodule Parlora.BrowserMediaTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, Limits, Native}
  alias Parlora.Channels.Browser.Media
  alias Parlora.Native.Opus

  defp media(queue_bytes) do
    init = %AdapterInit{
      session_id: Parlora.ID.new(),
      adapter_id: "test",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{audio_queue_bytes: queue_bytes, max_frame_bytes: 480}
    }

    options = %{jitter_ms: 0, max_rtp_packets: 32, max_age_ms: 200, playback_buffer_ms: 0}
    state = Media.activate_input(%{init: init, media: Media.open(init, options)})
    on_exit(fn -> Media.close(state.media) end)
    state
  end

  test "a valid 60 ms packet fits bounded decoding even with a minimal PCM queue" do
    # A 60 ms encoder frame is already larger than
    # the caller's 10 ms queue and demonstrates staging across separate reads.
    state = media(480)
    {:ok, packet} = Opus.encode(state.media.encoder, :binary.copy(<<0>>, 2880), 1440)
    packet = ExRTP.Packet.new(packet, sequence_number: 0, timestamp: 0, ssrc: 1)
    state = state |> Media.receive_packet(packet, 0) |> Media.capture(0)
    assert state.media.inbound.bytes == 480
    assert byte_size(state.media.input_pcm) == 2400
    refute Map.has_key?(state.media.discontinuities, :decoded_overflow)
  end

  test "unusable decoder state fails rather than reporting malformed packets forever" do
    state = media(9600)
    {:ok, packet} = Opus.encode(state.media.encoder, :binary.copy(<<0>>, 960), 480)
    packet = ExRTP.Packet.new(packet, sequence_number: 0, timestamp: 0, ssrc: 1)
    state = Media.receive_packet(state, packet, 0)
    :ok = Opus.close(state.media.decoder)
    assert {:error, %{code: :adapter_failed}} = Native.call(fn -> Media.capture(state, 0) end)
  end

  def record(_name, measurements, metadata, {session, owner}) do
    if metadata.session_id == session, do: send(owner, {:rendered, measurements})
  end

  test "partial packets count actual source, generated silence and tail padding separately" do
    state = media(9600)
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:parlora, :audio, :playout],
        &__MODULE__.record/4,
        {state.init.session_id, self()}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    first = Parlora.AudioFrame.pcm(<<2, 0>>, "partial", 0)
    second = Parlora.AudioFrame.pcm(:binary.copy(<<3, 0>>, 240), "partial", 1)
    {:ok, queue} = Parlora.AudioQueue.push(state.media.outbound, first)
    {:ok, queue} = Parlora.AudioQueue.push(queue, second)
    state = Media.update(state, %{outbound: queue})
    {_packet, state} = Media.output(state, 0)

    assert_receive {:rendered,
                    %{
                      source_bytes: 480,
                      source_peak: 3,
                      source_position_bytes: 0,
                      epoch: 0,
                      silence_bytes: 0,
                      padding_bytes: 0
                    }}

    assert state.media.output_pcm == <<3, 0>>
    {_packet, state} = Media.output(state, 10_000)

    assert_receive {:rendered,
                    %{
                      source_bytes: 2,
                      source_peak: 3,
                      source_position_bytes: 480,
                      silence_bytes: 478,
                      padding_bytes: 478
                    }}

    {_packet, state} = Media.output(state, 20_000)

    assert_receive {:rendered,
                    %{
                      source_bytes: 0,
                      source_peak: 0,
                      source_position_bytes: 482,
                      silence_bytes: 480,
                      padding_bytes: 0
                    }}

    assert state.media.rendered_source_bytes == 482
    assert state.media.rendered_silence_bytes == 958
    assert state.media.rendered_padding_bytes == 478
    assert state.media.rendered_source_bytes + state.media.rendered_silence_bytes == 3 * 480
    state = Media.clear(state, 1)
    {_packet, state} = Media.output(state, 30_000)
    assert_receive {:rendered, %{source_peak: 0, source_position_bytes: 482, epoch: 1}}

    quiet = Parlora.AudioFrame.pcm(:binary.copy(<<0>>, 480), "quiet", 0)
    {:ok, queue} = Parlora.AudioQueue.push(state.media.outbound, quiet)
    {_packet, _state} = state |> Media.update(%{outbound: queue}) |> Media.output(40_000)

    assert_receive {:rendered,
                    %{source_bytes: 480, source_peak: 0, source_position_bytes: 482, epoch: 1}}
  end
end
