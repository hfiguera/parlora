# Production Browser.Media/Playout/Opus with recorded channel-write and output ticks.
# Synthetic constant PCM replaces unavailable raw audio; this is a timing replay.
alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Limits}
alias Parlora.Channels.Browser.Media

defmodule RetryAudioReplay do
  def run(report, hold) do
    gap = report["gap"]["measurements"]
    start = gap["started_at_us"]

    init = %AdapterInit{
      session_id: "recorded-gap-#{gap["gap_id"]}",
      adapter_id: "browser",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    media =
      Media.open(init, %{
        jitter_ms: 0,
        max_rtp_packets: 32,
        max_age_ms: 200,
        playback_buffer_ms: 120
      })

    playout = %{media.playout | playing?: true}
    playout = if hold == :current, do: playout, else: %{playout | recovery_ms: hold, recovery_bytes: nil}
    state = %{init: init, media: %{media | playout: playout}}

    state = enqueue(state, 480, 6000)
    {_packet, state} = Media.output(state, -10_000)

    events =
      Enum.filter(report["events"], fn e ->
        e["kind"] in ["frame", "playout"] and e["measurements"]["at_us"] >= start and
          e["measurements"]["at_us"] <= gap["at_us"]
      end)

    # The writer can snapshot after the gap-completion event but before that
    # same Media.output call emits its playout telemetry. Completion records the
    # exact tick time, so use it when the final playout entry is absent.
    events =
      if Enum.any?(
           events,
           &(&1["kind"] == "playout" and &1["measurements"]["at_us"] == gap["at_us"])
         ) do
        events
      else
        events ++ [%{"kind" => "playout", "measurements" => %{"at_us" => gap["at_us"]}}]
      end

    try do
      final =
        Enum.reduce(events, state, fn e, state ->
          m = e["measurements"]

          if e["kind"] == "frame",
            do: enqueue(state, m["bytes"], 6000),
            else: elem(Media.output(state, m["at_us"] - start), 1)
        end)

      observed = final.media.playback_diagnostics.last_gap
      true = observed.cause == :source_resumed

      if hold == 200 do
        true = observed.duration_us == gap["duration_us"]
        true = observed.inserted_silence_us == gap["inserted_silence_us"]
        true = observed.source_unavailable_us == gap["source_unavailable_us"]
        true = observed.recovery_wait_us == gap["recovery_wait_us"]
      end

      %{gap_id: gap["gap_id"], recovery_cap_ms: hold, summary: observed}
    after
      Media.close(media)
    end
  end

  defp enqueue(state, bytes, sample) do
    frame =
      AudioFrame.pcm(
        :binary.copy(<<sample::little-signed-16>>, div(bytes, 2)),
        "recorded-timing",
        0
      )

    {:ok, queue} = AudioQueue.push(state.media.outbound, frame)
    Media.update(state, %{outbound: queue})
  end
end

rows =
  for id <- [3, 14], hold <- [200, 0, :current] do
    report = File.read!(Path.join(__DIR__, "audio-gap-#{id}.json")) |> Jason.decode!()
    RetryAudioReplay.run(report, hold)
  end

IO.inspect(
  Enum.map(
    rows,
    &%{
      gap_id: &1.gap_id,
      cap: &1.recovery_cap_ms,
      duration: &1.summary.duration_us,
      inserted: &1.summary.inserted_silence_us
    }
  ),
  limit: :infinity
)

File.write!(
  Path.join(__DIR__, "fixed-audio-replay-results.json"),
  Jason.encode!(
    %{
      provenance:
        "Recorded channel-write/output schedules with synthetic PCM; zero-wait is a diagnostic control, not a recommended policy.",
      rows: rows
    },
    pretty: true
  ) <> "\n"
)
