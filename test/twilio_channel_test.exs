defmodule Parlora.TwilioChannelTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Event, Limits}
  alias Parlora.Channels.Twilio

  @account "AC11111111111111111111111111111111"
  @call "CA22222222222222222222222222222222"
  @stream "MZ33333333333333333333333333333333"

  test "configuration must be able to hold a 20 ms wire packet" do
    format = AudioFormat.pcmu()
    {:ok, limits} = Limits.new([], format)

    init = %AdapterInit{
      session_id: "bounds",
      adapter_id: "channel",
      generation: 0,
      event_sink: self(),
      limits: limits,
      audio_format: format
    }

    options = [transport: self(), account_sid: @account, call_sid: @call]

    for setting <- [[max_inflight_ms: 10], [max_age_ms: 10]] do
      assert {:error, %{code: :invalid_argument}} = Twilio.start_link(init, options ++ setting)
    end

    too_small = %{init | limits: %{limits | audio_queue_bytes: 80, max_frame_bytes: 80}}
    assert {:error, %{code: :invalid_argument}} = Twilio.start_link(too_small, options)
  end

  test "stream readiness, byte-preserving input, pacing, and transport ownership" do
    channel = channel()
    assert {:error, %{code: :not_ready}} = Twilio.capabilities(channel)
    handshake(channel)
    assert_receive {:parlora_event, %Event{type: :ready}}
    assert {:ok, caps} = Twilio.capabilities(channel)
    assert caps.clear_scope == :remote_buffer
    data = :binary.copy(<<127, 255>>, 80)
    assert :ok = Twilio.receive_message(channel, media(data, 2, 1))
    assert {:ok, [frame]} = Twilio.read_audio(channel, 160)
    assert frame.data == data
    assert frame.duration_us == 20_000
    assert frame.format == AudioFormat.pcmu()

    assert :ok = Twilio.write_audio(channel, %{frame | playback_epoch: 0})
    assert :ok = Twilio.write_audio(channel, %{frame | sequence: 1, playback_epoch: 0})
    assert {:ok, [out, mark], delay} = Twilio.pull(channel)
    assert delay in 1..20
    assert Base.decode64!(out.media.payload) == data
    assert mark.event == "mark"
    # Exercise the not-yet-due branch with a controlled future deadline. A
    # preempted test process can otherwise outlive the real 20 ms send interval.
    :sys.replace_state(channel, fn state ->
      %{state | next_send_us: System.monotonic_time(:microsecond) + 1_000_000}
    end)

    assert {:ok, [], wait} = Twilio.pull(channel)
    assert wait > 0
    task = Task.async(fn -> Twilio.pull(channel) end)
    assert {:error, %{code: :invalid_argument}} = Task.await(task)
  end

  test "clear is idempotent, retires buffered output, and awaits a remote barrier" do
    channel = channel()
    handshake(channel)

    frame =
      AudioFrame.new(:binary.copy(<<255>>, 160), AudioFormat.pcmu(), "provider", 0,
        playback_epoch: 0
      )

    assert :ok = Twilio.write_audio(channel, frame)
    assert {:ok, [_media, mark], delay} = Twilio.pull(channel)
    assert delay in 1..20
    assert :ok = Twilio.write_audio(channel, %{frame | sequence: 1})
    assert :ok = Twilio.control(channel, "clear", {:clear_output, 1})
    assert_receive {:parlora_twilio, ^channel, {:send, [clear, barrier]}}
    assert clear.event == "clear"
    assert :ok = Twilio.control(channel, "clear", {:clear_output, 1})
    refute_receive {:parlora_twilio, ^channel, {:send, _messages}}, 5
    assert {:error, %{code: :invalid_argument}} = Twilio.write_audio(channel, frame)
    assert :ok = Twilio.write_audio(channel, %{frame | playback_epoch: 1, sequence: 2})
    assert {:ok, [], 10} = Twilio.pull(channel)
    assert :ok = Twilio.receive_message(channel, acknowledgment(mark.mark.name, 2))

    assert_receive {:parlora_event,
                    %Event{
                      type: :playback_observed,
                      payload: %{stage: :unknown, cause: :clear_race}
                    }}

    refute_receive {:parlora_event, %Event{type: :control_completed}}, 5
    assert :ok = Twilio.receive_message(channel, acknowledgment(barrier.mark.name, 3))

    assert_receive {:parlora_event,
                    %Event{
                      type: :control_completed,
                      command_id: "clear",
                      payload: %{scope: :remote_buffer}
                    }}

    assert {:ok, [_media, current], delay} = Twilio.pull(channel)
    assert delay in 1..20
    assert :ok = Twilio.receive_message(channel, acknowledgment(current.mark.name, 4))

    assert_receive {:parlora_event,
                    %Event{
                      type: :playback_observed,
                      payload: %{stage: :device_reported_playback, epoch: 1, sequence: 2}
                    }}
  end

  test "pre-ready capture remains bounded, reports loss, and explicit closure is stream-scoped" do
    channel = channel()
    handshake(channel)
    data = :binary.copy(<<255>>, 160)
    for n <- 1..20, do: assert(:ok == Twilio.receive_message(channel, media(data, n + 1, n)))

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{cause: :input_overflow}}}

    assert {:ok, frames} = Twilio.read_audio(channel, 1_600)
    assert Enum.count_until(frames, 11) == 10
    assert hd(frames).sequence == 10
    assert :ok = Twilio.close(channel, "close", :done)

    assert_receive {:parlora_event,
                    %Event{type: :closed, payload: %{scope: :stream, call_ended?: :unknown}}}

    assert {:error, %{code: :closed}} = Twilio.read_audio(channel, 160)
  end

  test "missing playback marks fail at the configured deadline with unknown outcomes" do
    channel = channel(mark_timeout_ms: 10)
    handshake(channel)

    frame =
      AudioFrame.new(:binary.copy(<<255>>, 160), AudioFormat.pcmu(), "provider", 0,
        playback_epoch: 0
      )

    assert :ok = Twilio.write_audio(channel, frame)
    assert {:ok, [_media, _mark], _wait} = Twilio.pull(channel)

    assert_receive {:parlora_event, %Event{type: :failed, payload: %{error: %{code: :timeout}}}},
                   500

    assert_receive {:parlora_event, %Event{type: :playback_observed, payload: %{stage: :unknown}}}
    assert_receive {:parlora_event, %Event{type: :closed}}
  end

  test "concurrent calls isolate audio, commands and a failed stream identity" do
    first = channel()
    second_call = "CA" <> String.duplicate("4", 32)
    second_stream = "MZ" <> String.duplicate("5", 32)
    second = channel(call_sid: second_call)
    handshake(first)
    handshake(second, second_call, second_stream)

    assert :ok = Twilio.receive_message(first, media(:binary.copy(<<1>>, 160), 2, 1))
    assert {:ok, []} = Twilio.read_audio(second, 160)

    assert {:error, %{code: :invalid_argument}} =
             Twilio.receive_message(first, %{media(<<2>>, 3, 2) | "streamSid" => second_stream})

    assert {:ok, _capabilities} = Twilio.capabilities(second)
    event = %{media(:binary.copy(<<2>>, 160), 2, 1) | "streamSid" => second_stream}
    assert :ok = Twilio.receive_message(second, event)
    assert {:ok, [frame]} = Twilio.read_audio(second, 160)
    assert frame.data == :binary.copy(<<2>>, 160)
    assert :ok = Twilio.control(second, "same-command-id", {:clear_output, 1})
    assert_receive {:parlora_twilio, ^second, {:send, [%{streamSid: ^second_stream}, _mark]}}
    assert {:error, %{code: :closed}} = Twilio.capabilities(first)
  end

  test "expired queued output is discarded without closing the stream" do
    channel = channel(max_age_ms: 20)
    handshake(channel)

    frame =
      AudioFrame.new(:binary.copy(<<1>>, 160), AudioFormat.pcmu(), "provider", 0,
        playback_epoch: 0
      )

    assert :ok = Twilio.write_audio(channel, frame)
    Process.sleep(25)
    assert {:ok, [], _wait} = Twilio.pull(channel)

    assert_receive {:parlora_event,
                    %Event{
                      type: :audio_discontinuity,
                      payload: %{cause: :output_stale, dropped_bytes: 160}
                    }}

    assert {:ok, _caps} = Twilio.capabilities(channel)
    refute_received {:parlora_twilio, ^channel, :close}
  end

  defp channel(options \\ []) do
    format = AudioFormat.pcmu()
    {:ok, limits} = Limits.new([], format)

    init = %AdapterInit{
      session_id: "twilio-test",
      adapter_id: "channel",
      generation: 0,
      event_sink: self(),
      limits: limits,
      audio_format: format
    }

    {:ok, pid} =
      Twilio.start_link(
        init,
        Keyword.merge([transport: self(), account_sid: @account, call_sid: @call], options)
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp handshake(channel, call \\ @call, stream \\ @stream) do
    assert :ok =
             Twilio.receive_message(channel, %{
               "event" => "connected",
               "protocol" => "Call",
               "version" => "1.0.0"
             })

    assert :ok =
             Twilio.receive_message(channel, %{
               "event" => "start",
               "sequenceNumber" => "1",
               "streamSid" => stream,
               "start" => %{
                 "accountSid" => @account,
                 "callSid" => call,
                 "streamSid" => stream,
                 "tracks" => ["inbound"],
                 "mediaFormat" => %{
                   "encoding" => "audio/x-mulaw",
                   "sampleRate" => 8_000,
                   "channels" => 1
                 }
               }
             })
  end

  defp media(data, sequence, chunk),
    do: %{
      "event" => "media",
      "sequenceNumber" => Integer.to_string(sequence),
      "streamSid" => @stream,
      "media" => %{
        "track" => "inbound",
        "chunk" => Integer.to_string(chunk),
        "timestamp" => Integer.to_string((chunk - 1) * 20),
        "payload" => Base.encode64(data)
      }
    }

  defp acknowledgment(name, sequence),
    do: %{
      "event" => "mark",
      "sequenceNumber" => Integer.to_string(sequence),
      "streamSid" => @stream,
      "mark" => %{"name" => name}
    }
end
