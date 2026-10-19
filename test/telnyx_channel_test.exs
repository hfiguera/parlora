defmodule Parlora.TelnyxChannelTest do
  # The paced playback-window test deliberately retains the default mark
  # deadline. Run without competing async modules so scheduler delays do not
  # turn its brief simulated pause into a missing-mark timeout.
  use ExUnit.Case, async: false
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Event, Limits}
  alias Parlora.Channels.Telnyx

  test "reorders initial media, ignores duplicates, and bounds waiting across a gap" do
    channel = start_channel(reorder_ms: 10)
    assert :ok = Telnyx.receive_message(channel, media(2, 3, "b"))
    assert :ok = Telnyx.receive_message(channel, media(1, 2, "a"))
    assert {:ok, []} = Telnyx.read_audio(channel, 160)
    Process.sleep(12)
    assert {:ok, frames} = Telnyx.read_audio(channel, 160)
    assert Enum.map(frames, & &1.data) == ["a", "b"]
    assert :ok = Telnyx.receive_message(channel, media(2, 4, "duplicate"))
    assert :ok = Telnyx.receive_message(channel, media(4, 5, "d"))
    assert {:ok, []} = Telnyx.read_audio(channel, 160)
    Process.sleep(12)
    assert {:ok, [frame]} = Telnyx.read_audio(channel, 160)
    assert frame.data == "d"
    assert frame.discontinuity
    assert_receive {:parlora_event, %Event{type: :audio_discontinuity}}
    assert :ok = Telnyx.receive_message(channel, media(3, 6, "late"))
    assert {:ok, []} = Telnyx.read_audio(channel, 160)
  end

  test "clear races remain unknown, fresh marks establish Telnyx evidence, and tail packets meet 20 ms" do
    channel = start_channel()

    frame =
      AudioFrame.new(:binary.copy(<<127>>, 80), AudioFormat.pcmu(), "provider", 0,
        playback_epoch: 0
      )

    assert :ok = Telnyx.write_audio(channel, frame)
    assert {:ok, [], _wait} = Telnyx.pull(channel)
    Process.sleep(22)
    assert {:ok, [packet, old_mark], _wait} = Telnyx.pull(channel)
    assert Base.decode64!(packet.media.payload) == frame.data <> :binary.copy(<<255>>, 80)
    refute Map.has_key?(packet, :streamSid)
    assert :ok = Telnyx.control(channel, "clear", {:clear_output, 1})
    assert_receive {:parlora_telnyx, ^channel, {:send, [%{event: "clear"}, barrier]}}
    assert :ok = Telnyx.receive_message(channel, mark(old_mark.mark.name, 2))

    assert_receive {:parlora_event,
                    %Event{
                      type: :playback_observed,
                      payload: %{stage: :unknown, cause: :clear_race}
                    }}

    assert :ok = Telnyx.receive_message(channel, mark(barrier.mark.name, 3))
    assert_receive {:parlora_event, %Event{type: :control_completed, command_id: "clear"}}

    assert :ok =
             Telnyx.write_audio(channel, %{
               frame
               | data: :binary.copy(<<255>>, 160),
                 duration_us: 20_000,
                 playback_epoch: 1
             })

    assert {:ok, [_packet, fresh], _wait} = Telnyx.pull(channel)
    assert :ok = Telnyx.receive_message(channel, mark(fresh.mark.name, 4))

    assert_receive {:parlora_event,
                    %Event{
                      type: :playback_observed,
                      payload: %{stage: :device_reported_playback, boundary: :telnyx_mark}
                    }}
  end

  test "invalid call identity, malformed frames and reorder capacity fail explicitly" do
    channel = start_channel(handshake: false)
    assert {:error, %{code: :not_ready}} = Telnyx.capabilities(channel)
    assert :ok = Telnyx.receive_message(channel, %{"event" => "connected", "version" => "1.0.0"})
    wrong = put_in(start_message(), ["start", "call_control_id"], "another-call")
    assert {:error, _error} = Telnyx.receive_message(channel, wrong)
    assert_receive {:parlora_event, %Event{type: :failed}}

    channel = start_channel()
    invalid = put_in(media(1, 2, "x"), ["media", "payload"], "!invalid")
    assert {:error, _error} = Telnyx.receive_message(channel, invalid)

    channel = start_channel(reorder_ms: 200)
    assert :ok = Telnyx.receive_message(channel, media(1, 2, :binary.copy(<<255>>, 1_600)))

    assert {:error, %{details: %{reason: :reorder_overflow}}} =
             Telnyx.receive_message(channel, media(2, 3, "x"))
  end

  test "another process cannot inject wire messages; closure reports stream scope" do
    channel = start_channel()
    task = Task.async(fn -> Telnyx.receive_message(channel, media(1, 2, "x")) end)
    assert {:error, %{code: :invalid_argument}} = Task.await(task)

    stop = %{
      "event" => "stop",
      "stream_id" => "stream",
      "sequence_number" => "2",
      "stop" => %{"call_control_id" => "call"}
    }

    assert :ok = Telnyx.receive_message(channel, stop)

    assert_receive {:parlora_event,
                    %Event{type: :closed, payload: %{scope: :stream, call_ended?: :unknown}}}

    assert {:error, %{code: :closed}} = Telnyx.read_audio(channel, 160)
  end

  test "unsupported codecs, rates, and channel counts fail before readiness" do
    for {field, value} <- [{"encoding", "PCMA"}, {"sample_rate", 16_000}, {"channels", 2}] do
      channel = start_channel(handshake: false)

      assert :ok =
               Telnyx.receive_message(channel, %{"event" => "connected", "version" => "1.0.0"})

      frame = put_in(start_message(), ["start", "media_format", field], value)
      assert {:error, %{code: :invalid_argument}} = Telnyx.receive_message(channel, frame)
      assert {:error, _not_ready} = Telnyx.capabilities(channel)
    end
  end

  test "concurrent channel audio and playback epochs remain isolated" do
    first = start_channel(reorder_ms: 1)
    second = start_channel(reorder_ms: 1)
    assert :ok = Telnyx.receive_message(first, media(1, 2, "first"))
    assert :ok = Telnyx.receive_message(second, media(1, 2, "second"))
    Process.sleep(3)
    assert {:ok, [%{data: "first"}]} = Telnyx.read_audio(first, 160)
    assert {:ok, [%{data: "second"}]} = Telnyx.read_audio(second, 160)

    bytes = :binary.copy(<<127>>, 160)
    frame = AudioFrame.new(bytes, AudioFormat.pcmu(), "provider", 0, playback_epoch: 0)
    assert :ok = Telnyx.write_audio(second, frame)
    assert :ok = Telnyx.control(first, "clear-first", {:clear_output, 1})
    assert {:ok, [packet, _mark], _wait} = Telnyx.pull(second)
    assert Base.decode64!(packet.media.payload) == bytes
  end

  test "delayed marks discard stale local audio and resume fresh paced output" do
    channel = start_channel(max_inflight_ms: 20, max_age_ms: 30, mark_timeout_ms: 1_000)
    old = output_frame(0, 1)
    assert :ok = Telnyx.write_audio(channel, old)
    assert {:ok, [_packet, first_mark], _wait} = Telnyx.pull(channel)
    assert :ok = Telnyx.write_audio(channel, output_frame(1, 2))
    Process.sleep(45)
    assert {:ok, [], _wait} = Telnyx.pull(channel)

    assert_receive {:parlora_event,
                    %Event{
                      type: :audio_discontinuity,
                      payload: %{
                        cause: :output_stale,
                        dropped_bytes: 160,
                        dropped_frames: 1,
                        dropped_duration_us: 20_000
                      }
                    }}

    assert {:ok, _caps} = Telnyx.capabilities(channel)
    assert :ok = Telnyx.receive_message(channel, mark(first_mark.mark.name, 2))
    fresh = output_frame(2, 3)
    assert :ok = Telnyx.write_audio(channel, fresh)
    assert {:ok, [packet, second_mark], wait} = Telnyx.pull(channel)
    assert Base.decode64!(packet.media.payload) == fresh.data
    assert wait in 1..20
    assert :ok = Telnyx.write_audio(channel, output_frame(3, 4))
    assert {:ok, [], delay} = Telnyx.pull(channel)
    assert delay > 0
    assert :ok = Telnyx.receive_message(channel, mark(second_mark.mark.name, 3))
    refute_received {:parlora_event, %Event{type: :failed}}
    assert :sys.get_state(channel).playback.bytes == 0
  end

  test "default playback window survives a brief mark pause and retains finite bounds" do
    channel = start_channel()

    marks =
      for n <- 0..24 do
        assert :ok = Telnyx.write_audio(channel, output_frame(n, 1))
        assert {:ok, [_packet, marker], wait} = Telnyx.pull(channel)
        Process.sleep(wait)
        marker.mark.name
      end

    assert :sys.get_state(channel).playback.bytes == 4_000
    for n <- 25..34, do: assert(:ok == Telnyx.write_audio(channel, output_frame(n, 2)))
    assert {:error, %{code: :backpressure}} = Telnyx.write_audio(channel, output_frame(35, 2))
    assert :sys.get_state(channel).outbound.bytes == 1_600
    assert {:ok, [], _wait} = Telnyx.pull(channel)
    Process.sleep(220)
    assert {:ok, [], _wait} = Telnyx.pull(channel)
    assert :sys.get_state(channel).outbound.bytes == 0
    assert :sys.get_state(channel).playback.bytes == 4_000
    refute_received {:parlora_event, %Event{type: :failed}}

    for {name, n} <- Enum.with_index(marks, 2),
        do: assert(:ok == Telnyx.receive_message(channel, mark(name, n)))

    fresh = output_frame(36, 3)
    assert :ok = Telnyx.write_audio(channel, fresh)
    assert {:ok, [packet, _marker], _wait} = Telnyx.pull(channel)
    assert Base.decode64!(packet.media.payload) == fresh.data
    assert {:ok, _caps} = Telnyx.capabilities(channel)
  end

  test "queue expiration cannot reset the deadline for permanently missing marks" do
    channel = start_channel(max_inflight_ms: 20, max_age_ms: 20, mark_timeout_ms: 5_000)
    assert :ok = Telnyx.write_audio(channel, output_frame(0, 1))
    assert {:ok, [_packet, _mark], _wait} = Telnyx.pull(channel)
    pending = :sys.get_state(channel).playback.pending
    assert :ok = Telnyx.write_audio(channel, output_frame(1, 2))
    Process.sleep(30)
    assert {:ok, [], _wait} = Telnyx.pull(channel)

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{cause: :output_stale}}}

    # Expiring queued audio must preserve the original mark timestamp. This
    # checks the deadline directly instead of using a narrow wall-clock window.
    assert :sys.get_state(channel).playback.pending == pending

    # Move that unchanged mark past its deadline, then exercise the real
    # watchdog without racing a 160 ms window on a shared runner.
    :sys.replace_state(channel, fn state ->
      expired =
        Map.new(state.playback.pending, fn {name, record} ->
          {name, %{record | sent_at_us: System.monotonic_time(:microsecond) - 5_000_000}}
        end)

      %{state | playback: %{state.playback | pending: expired}}
    end)

    send(channel, :watchdog)

    assert_receive {:parlora_event,
                    %Event{
                      type: :failed,
                      payload: %{
                        error: %{
                          code: :timeout,
                          details: %{
                            reason: :playback_ack_timeout,
                            pending_marks: 1,
                            inflight_bytes: 160
                          }
                        }
                      }
                    }},
                   5_000

    assert_receive {:parlora_event,
                    %Event{
                      type: :playback_observed,
                      payload: %{stage: :unknown, cause: :stream_closed}
                    }}

    assert {:error, %{code: :closed}} = Telnyx.capabilities(channel)
  end

  test "a delayed clear barrier also discards stale new audio without fabricating playback" do
    channel = start_channel(max_age_ms: 20, mark_timeout_ms: 1_000)
    assert :ok = Telnyx.control(channel, "clear", {:clear_output, 1})
    assert_receive {:parlora_telnyx, ^channel, {:send, [_clear, barrier]}}
    assert :ok = Telnyx.write_audio(channel, %{output_frame(0, 1) | playback_epoch: 1})
    Process.sleep(30)
    assert {:ok, [], _wait} = Telnyx.pull(channel)
    refute_received {:parlora_event, %Event{type: :control_completed}}
    assert :ok = Telnyx.receive_message(channel, mark(barrier.mark.name, 2))
    assert_receive {:parlora_event, %Event{type: :control_completed, command_id: "clear"}}

    refute_received {:parlora_event,
                     %Event{
                       type: :playback_observed,
                       payload: %{stage: :device_reported_playback}
                     }}

    assert :ok = Telnyx.write_audio(channel, %{output_frame(1, 2) | playback_epoch: 1})
    assert {:ok, [_packet, _mark], _wait} = Telnyx.pull(channel)
    assert {:error, %{code: :invalid_argument}} = Telnyx.write_audio(channel, output_frame(2, 3))
  end

  defp output_frame(sequence, byte),
    do:
      AudioFrame.new(:binary.copy(<<byte>>, 160), AudioFormat.pcmu(), "provider", sequence,
        playback_epoch: 0
      )

  defp start_channel(options \\ []) do
    {:ok, limits} = Limits.new([], AudioFormat.pcmu())

    init = %AdapterInit{
      session_id: "telnyx-test",
      adapter_id: "channel",
      generation: 0,
      event_sink: self(),
      audio_format: AudioFormat.pcmu(),
      limits: limits
    }

    channel =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Telnyx, :start_link,
           [
             init,
             Keyword.merge(
               [transport: self(), call_control_id: "call", call_session_id: "session"],
               options
             )
           ]},
        restart: :temporary
      })

    if Keyword.get(options, :handshake, true) do
      :ok = Telnyx.receive_message(channel, %{"event" => "connected", "version" => "1.0.0"})
      :ok = Telnyx.receive_message(channel, start_message())
    end

    channel
  end

  defp start_message do
    %{
      "event" => "start",
      "sequence_number" => "1",
      "stream_id" => "stream",
      "start" => %{
        "call_control_id" => "call",
        "call_session_id" => "session",
        "media_format" => %{"encoding" => "PCMU", "sample_rate" => 8_000, "channels" => 1}
      }
    }
  end

  defp media(chunk, sequence, bytes) do
    %{
      "event" => "media",
      "stream_id" => "stream",
      "sequence_number" => to_string(sequence),
      "media" => %{
        "track" => "inbound",
        "chunk" => to_string(chunk),
        "timestamp" => to_string(chunk * 160),
        "payload" => Base.encode64(bytes)
      }
    }
  end

  defp mark(name, sequence),
    do: %{
      "event" => "mark",
      "stream_id" => "stream",
      "sequence_number" => to_string(sequence),
      "mark" => %{"name" => name}
    }
end
