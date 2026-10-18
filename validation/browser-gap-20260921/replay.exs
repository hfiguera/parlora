# Controlled production Browser.Media/Playout/Opus execution. These arrival/tick
# schedules are constructed controls, NOT recovered timestamps from the live call.
alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Limits}
alias Parlora.Channels.Browser.Media

defmodule BrowserGapControl do
  def run(name, return_tick, mode, jitter?) do
    init = %AdapterInit{
      session_id: "gap-control",
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

    media =
      if mode == :none, do: %{media | playout: %{media.playout | recovery_ms: 0}}, else: media

    start = %{init: init, media: media} |> enqueue(4960)

    try do
      {final, trace} =
        Enum.reduce(0..(return_tick + 21), {start, []}, fn tick, {state, trace} ->
          # The deadline tick is 890 us earlier relative to the gap-start tick.
          # Individual intervals remain 9.11–10 ms; this is not a scheduling freeze.
          now = tick * 10_000 - if(jitter? and tick >= 46, do: 890, else: 0)
          state = if tick == return_tick, do: enqueue(state, 5344), else: state
          # Explicit old-policy control, independent of current production tuning.
          state =
            if tick == return_tick and mode == :adaptive,
              do:
                put_in(
                  state.media.playout.buffer_ms,
                  min(200, max(120, div(now - 120_000, 1000)))
                ),
              else: state

          state =
            if tick == return_tick and mode == :pressure_hint,
              do: Media.release_recovery(state, 0),
              else: state

          prior = state.media.playout
          queue_bytes = state.media.outbound.bytes
          {_packet, next} = Media.output(state, now)

          row = %{
            tick: tick,
            at_us: now,
            queued_bytes: queue_bytes,
            source_bytes: next.media.playout.source_bytes,
            source_return?: tick == return_tick,
            recovery_wait?: next.media.playout.recovering? and queue_bytes > 0,
            playing_source?: next.media.playout.source_bytes > prior.source_bytes
          }

          {next, [row | trace]}
        end)

      summary = final.media.playback_diagnostics.last_gap
      true = summary.cause == :source_resumed
      true = summary.peak_before == 4960 and summary.peak_after == 5344
      trace = Enum.reverse(trace)
      returned = Enum.find(trace, & &1.source_return?).at_us

      %{
        name: name,
        mode: mode,
        schedule: if(jitter?, do: "890 us relative tick variation", else: "regular 10 ms"),
        source_available_after_empty_us: returned - summary.started_at_us,
        additional_wait_us: summary.started_at_us + summary.duration_us - returned,
        summary: summary,
        trace:
          Enum.filter(
            trace,
            &(&1.at_us >= summary.started_at_us and
                &1.at_us <= summary.started_at_us + summary.duration_us)
          )
      }
    after
      Media.close(media)
    end
  end

  defp enqueue(state, sample) do
    queue =
      Enum.reduce(0..11, state.media.outbound, fn index, queue ->
        frame = AudioFrame.pcm(:binary.copy(<<sample::little-signed-16>>, 240), "control", index)
        {:ok, queue} = AudioQueue.push(queue, frame)
        queue
      end)

    Media.update(state, %{outbound: queue})
  end
end

rows = [
  BrowserGapControl.run("30ms_shortage", 15, :adaptive, false),
  BrowserGapControl.run("70ms_shortage", 19, :adaptive, false),
  BrowserGapControl.run("170ms_shortage", 29, :adaptive, false),
  BrowserGapControl.run("170ms_shortage_with_tick_variation", 29, :adaptive, true),
  BrowserGapControl.run("zero_hold_control", 29, :none, true),
  BrowserGapControl.run("later_source_with_release_hint", 47, :pressure_hint, true)
]

[short, medium, regular, varied, zero, released] = rows
true = short.summary.inserted_silence_us == 150_000
true = medium.summary.inserted_silence_us == 190_000
true = regular.summary.inserted_silence_us == 340_000
true = varied.summary.duration_us == 349_110
true = varied.summary.inserted_silence_us == 350_000
true = varied.additional_wait_us == 179_110
true = zero.summary.inserted_silence_us == 170_000
# An identical observation can hide a different split between source shortage
# and recovery. This invalidates attributing the original 350 ms from its summary alone.
legacy_keys = [
  :cause,
  :peak_before,
  :peak_after,
  :started_at_us,
  :duration_us,
  :inserted_silence_us,
  :boundary,
  :epoch,
  :silence_bytes,
  :gap_id
]

true = Map.take(released.summary, legacy_keys) == Map.take(varied.summary, legacy_keys)
# New observations distinguish these formerly indistinguishable histories.
true = released.summary.recovery_release_reason == :pressure
true = varied.summary.recovery_release_reason == :deadline
true = released.additional_wait_us == 0

current = BrowserGapControl.run("fixed_refill", 29, :current, true)
true = current.summary.inserted_silence_us == 290_000
true = current.summary.source_unavailable_us == 170_000
true = current.summary.recovery_wait_us == 120_000
true = current.summary.recovery_release_reason == :deadline
rows = rows ++ [current]

File.write!(
  Path.join(__DIR__, "replay-fix-results.json"),
  Jason.encode!(
    %{
      provenance:
        "Constructed production media controls. Not an exact live arrival replay or proof of the initial live depletion cause.",
      rows: rows
    },
    pretty: true
  ) <> "\n"
)

Enum.each(rows, &IO.inspect(Map.delete(&1, :trace)))
