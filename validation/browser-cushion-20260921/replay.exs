# Recorded timing, synthetic samples. This does not model future arrivals or hearing.
alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Limits}
alias Parlora.Channels.Browser.Media

defmodule CushionReplay do
  def run(report, policy) do
    gap = report["gap"]["measurements"]
    start = gap["started_at_us"]
    init = %AdapterInit{
      session_id: "cushion-replay", adapter_id: "browser", generation: 0,
      event_sink: self(), audio_format: %AudioFormat{}, limits: %Limits{}
    }
    media = Media.open(init, %{jitter_ms: 0, max_rtp_packets: 32, max_age_ms: 200, playback_buffer_ms: 120})
    playout = case policy do
      :current -> media.playout
      :historical -> %{media.playout | recovery_bytes: 9_600}
      :one_batch -> %{media.playout | recovery_bytes: 4_800}
      :disabled -> %{media.playout | recovery_ms: 0}
    end
    state = %{init: init, media: %{media | playout: %{playout | playing?: true}}}
    {_packet, state} = Media.output(enqueue(state, 480), -10_000)
    events = Enum.filter(report["events"], fn e ->
      e["kind"] in ["frame", "playout"] and e["measurements"]["at_us"] >= start
    end)
    try do
      {state, received} = Enum.reduce(events, {state, 480}, fn e, {state, received} ->
        m = e["measurements"]
        if e["kind"] == "frame" do
          {enqueue(state, m["bytes"]), received + m["bytes"]}
        else
          {elem(Media.output(state, m["at_us"] - start), 1), received}
        end
      end)
      observed = state.media.playback_diagnostics.last_gap
      if policy == :historical do
        for key <- [:duration_us, :inserted_silence_us, :source_unavailable_us, :recovery_wait_us, :resume_queue_bytes] do
          true = observed[key] == gap[Atom.to_string(key)]
        end
      end
      last = List.last(events)["measurements"]["at_us"] - start
      drained = Enum.reduce(1..100, state, fn tick, state ->
        elem(Media.output(state, last + tick * 10_000), 1)
      end)
      true = drained.media.playout.source_bytes == received
      %{policy: policy, gap: observed, source_bytes: received, preserved_source_bytes: drained.media.playout.source_bytes}
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
report = File.read!(Path.join(__DIR__, "gap-2.json")) |> Jason.decode!()
rows = for policy <- [:historical, :current, :one_batch, :disabled], do: CushionReplay.run(report, policy)
for row <- rows do
  IO.inspect(%{policy: row.policy, inserted_ms: div(row.gap.inserted_silence_us, 1000), unavailable_us: row.gap.source_unavailable_us, recovery_us: row.gap.recovery_wait_us})
end
File.write!(Path.join(__DIR__, "fixed-replay-results.json"), Jason.encode!(%{provenance: "Production media replay with synthetic PCM and recorded channel-write/playout times. Alternative thresholds are diagnostic controls, not a validated fix.", rows: rows}, pretty: true) <> "\n")
