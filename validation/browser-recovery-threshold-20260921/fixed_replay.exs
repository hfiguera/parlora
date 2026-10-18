# Recorded timing, synthetic samples. This does not model future arrivals or hearing.
alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Limits}
alias Parlora.Channels.Browser.Media

defmodule ThresholdReplay do
  def run(report, policy) do
    gap = report["gap"]["measurements"]
    start = gap["started_at_us"]

    init = %AdapterInit{
      session_id: "cushion-replay",
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

    playout =
      case policy do
        :current -> media.playout
        :disabled -> %{media.playout | recovery_ms: 0}
      end

    state = %{init: init, media: %{media | playout: %{playout | playing?: true}}}
    {_packet, state} = Media.output(enqueue(state, 480), -10_000)

    events =
      Enum.filter(report["events"], fn e ->
        e["kind"] in ["frame", "playout"] and e["measurements"]["at_us"] >= start
      end)

    try do
      {state, received} =
        Enum.reduce(events, {state, 480}, fn e, {state, received} ->
          m = e["measurements"]

          if e["kind"] == "frame" do
            {enqueue(state, m["bytes"]), received + m["bytes"]}
          else
            {elem(Media.output(state, m["at_us"] - start), 1), received}
          end
        end)

      observed = state.media.playback_diagnostics.last_gap
      last = List.last(events)["measurements"]["at_us"] - start

      drained =
        Enum.reduce(1..100, state, fn tick, state ->
          elem(Media.output(state, last + tick * 10_000), 1)
        end)

      true = drained.media.playout.source_bytes == received

      %{
        recorded_gap: gap["gap_id"],
        policy: policy,
        gap: observed,
        source_bytes: received,
        preserved_source_bytes: drained.media.playout.source_bytes
      }
    after
      Media.close(media)
    end
  end

  defp enqueue(state, bytes) do
    frame = AudioFrame.pcm(:binary.copy(<<6000::little-signed-16>>, div(bytes, 2)), "replay", 0)
    {:ok, queue} = AudioQueue.push(state.media.outbound, frame)
    Media.update(state, %{outbound: queue})
  end
end

rows =
  for id <- [4, 9, 14], policy <- [:current, :disabled] do
    report = File.read!(Path.join(__DIR__, "gap-#{id}.json")) |> Jason.decode!()
    ThresholdReplay.run(report, policy)
  end

for row <- rows do
  IO.inspect(%{
    id: row.recorded_gap,
    policy: row.policy,
    inserted_ms: div(row.gap.inserted_silence_us, 1000),
    unavailable_us: row.gap.source_unavailable_us,
    recovery_us: row.gap.recovery_wait_us
  })
end

File.write!(
  Path.join(__DIR__, "fixed-replay-results.json"),
  Jason.encode!(
    %{
      provenance:
        "Production media replay with synthetic PCM and recorded channel-write/playout times. Diagnostic controls do not establish a safe production policy or prove heard speech.",
      rows: rows
    }, pretty: true) <> "\n"
)
