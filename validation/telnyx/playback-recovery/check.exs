alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Limits}
alias Parlora.Channels.{Telnyx, MediaStream.Playback}
{:ok, limits} = Limits.new([], AudioFormat.pcmu())

init = %AdapterInit{
  session_id: "probe",
  adapter_id: "channel",
  generation: 0,
  event_sink: self(),
  audio_format: AudioFormat.pcmu(),
  limits: limits
}

for acknowledge? <- [true, false] do
  {:ok, channel} =
    Telnyx.start_link(init,
      transport: self(),
      call_control_id: "probe-call",
      call_session_id: "probe-session"
    )

  :ok = Telnyx.receive_message(channel, %{"event" => "connected", "version" => "1.0.0"})

  :ok =
    Telnyx.receive_message(channel, %{
      "event" => "start",
      "sequence_number" => "1",
      "stream_id" => "probe-stream",
      "start" => %{
        "call_control_id" => "probe-call",
        "call_session_id" => "probe-session",
        "media_format" => %{"encoding" => "PCMU", "sample_rate" => 8000, "channels" => 1}
      }
    })

  started = System.monotonic_time(:microsecond)

  for index <- 0..24 do
    frame =
      AudioFrame.new(:binary.copy(<<255>>, 160), AudioFormat.pcmu(), "probe", index,
        playback_epoch: 0
      )

    :ok = Telnyx.write_audio(channel, frame)
    {:ok, [_packet, mark], wait} = Telnyx.pull(channel)

    if acknowledge? do
      :ok =
        Telnyx.receive_message(channel, %{
          "event" => "mark",
          "sequence_number" => to_string(index + 2),
          "stream_id" => "probe-stream",
          "mark" => %{"name" => mark.mark.name}
        })
    end

    Process.sleep(wait)
  end

  state = :sys.get_state(channel)
  now = System.monotonic_time(:microsecond)

  IO.inspect(
    %{
      acknowledgments: acknowledge?,
      elapsed_ms: div(now - started, 1000),
      inflight_bytes: state.playback.bytes,
      mark_deadline_expired:
        Playback.expired?(state.playback, now, state.settings.mark_timeout_ms)
    }, label: "before_queue")

  frame =
    AudioFrame.new(:binary.copy(<<255>>, 160), AudioFormat.pcmu(), "probe", 25, playback_epoch: 0)

  :ok = Telnyx.write_audio(channel, frame)
  IO.inspect(Telnyx.pull(channel), label: "next_pull", limit: 5)
  Process.sleep(215)
  result = Telnyx.pull(channel)
  state = :sys.get_state(channel)
  now = System.monotonic_time(:microsecond)

  IO.inspect(
    %{
      acknowledgments: acknowledge?,
      elapsed_ms: div(now - started, 1000),
      status: state.status,
      result: inspect(result),
      settings: state.settings
    }, label: "result")

  if acknowledge? do
    unless state.status == :ready, do: raise("Control failed")
  else
    unless state.status == :ready and now - started < 2_000_000,
      do: raise("Brief pause closed the stream")

    for n <- 0..24 do
      :ok =
        Telnyx.receive_message(channel, %{
          "event" => "mark",
          "sequence_number" => to_string(n + 2),
          "stream_id" => "probe-stream",
          "mark" => %{"name" => "parlora-#{n}"}
        })
    end

    fresh =
      AudioFrame.new(:binary.copy(<<127>>, 160), AudioFormat.pcmu(), "probe", 26,
        playback_epoch: 0
      )

    :ok = Telnyx.write_audio(channel, fresh)
    {:ok, [packet, _mark], wait} = Telnyx.pull(channel)
    unless Base.decode64!(packet.media.payload) == fresh.data, do: raise("Resumed stale audio")
    IO.inspect(%{recovered: true, pacing_wait_ms: wait}, label: "recovery")
  end

  receive do
    {:parlora_event, %{type: :failed, payload: payload}} -> IO.inspect(payload, label: "failure")
  after
    0 -> :ok
  end

  GenServer.stop(channel)
end
