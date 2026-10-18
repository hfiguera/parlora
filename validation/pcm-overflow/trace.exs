defmodule PCMOverflowTrace do
  def record(name, measurements, metadata, agent) do
    if metadata[:direction] in [nil, :output] do
      event = %{
        kind: List.last(name),
        at_us: System.monotonic_time(:microsecond),
        measurements: measurements,
        metadata: metadata
      }

      Agent.cast(agent, fn {events, count} ->
        events = :queue.in(event, events)

        if count == 30_000,
          do: {:queue.drop(events), count},
          else: {events, count + 1}
      end)
    end
  end
end

{:ok, agent} = Agent.start_link(fn -> {:queue.new(), 0} end)

:ok =
  :telemetry.attach_many(
    "pcm-overflow-trace",
    [
      [:parlora, :provider, :audio_received],
      [:parlora, :provider, :audio_read],
      [:parlora, :audio, :tick],
      [:parlora, :audio, :frame],
      [:parlora, :audio, :playout],
      [:parlora, :audio, :poll]
    ],
    &PCMOverflowTrace.record/4,
    agent
  )

try do
  Code.require_file("../telnyx/save-announcements/live.exs", __DIR__)
after
  :telemetry.detach("pcm-overflow-trace")
  events = Agent.get(agent, fn {events, _count} -> :queue.to_list(events) end)
  output = System.fetch_env!("PARLORA_TRACE_OUTPUT")
  File.write!(output, Jason.encode!(%{events: events}, pretty: true))
end
