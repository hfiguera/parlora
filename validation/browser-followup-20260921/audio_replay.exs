# Synthetic controls matching the two observed gap durations; not original arrivals.
alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Limits}
alias Parlora.Channels.Browser.Media

defmodule RecoveryGapReplay do
  def run(return_after_ms, mode) do
    recovery_ms = if mode == :none, do: 0, else: 200

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

    media = %{media | playout: %{media.playout | recovery_ms: recovery_ms}}
    start = %{init: init, media: media} |> enqueue(1_000)
    returned_at = 120_000 + return_after_ms * 1_000

    try do
      final =
        Enum.reduce(0..(returned_at + 210_000)//10_000, start, fn now, state ->
          state = if now == returned_at, do: enqueue(state, 2_000), else: state
          # Model the original fixed hold explicitly; production uses the actual
          # queue-empty timestamp. Do not mistake this baseline for current code.
          state =
            if now == returned_at and mode == :historical,
              do: put_in(state.media.playout.buffer_ms, 200),
              else: state

          # Preserve the prior adaptive-policy control after production changed.
          state =
            if now == returned_at and mode == :adaptive,
              do: put_in(state.media.playout.buffer_ms, min(200, max(120, return_after_ms))),
              else: state

          {_packet, state} = Media.output(state, now)
          state
        end)

      summary = final.media.playback_diagnostics.last_gap
      true = summary.cause == :source_resumed
      true = summary.peak_before == 1_000 and summary.peak_after == 2_000

      hold_ms =
        if mode == :adaptive, do: min(200, max(120, return_after_ms)), else: recovery_ms

      true = summary.duration_us == (return_after_ms + hold_ms) * 1_000
      true = summary.inserted_silence_us == summary.duration_us

      %{
        source_return_after_empty_ms: return_after_ms,
        recovery_setting_ms: recovery_ms,
        mode: mode,
        added_recovery_ms: hold_ms,
        inserted_silence_ms: div(summary.inserted_silence_us, 1_000),
        peak_before: summary.peak_before,
        peak_after: summary.peak_after,
        pacing_tick_ms: 10,
        upstream_pressure_release: false
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

rows =
  for missing_ms <- [30, 70, 190, 500],
      mode <- [:historical, :adaptive, :none],
      do: RecoveryGapReplay.run(missing_ms, mode)

File.write!(
  Path.join(__DIR__, "audio-fix-results.json"),
  Jason.encode!(
    %{
      provenance:
        "Synthetic, regular-tick production Media controls; matching durations do not reconstruct original provider or channel arrivals.",
      rows: rows
    },
    pretty: true
  ) <> "\n"
)

IO.inspect(rows, limit: :infinity)
