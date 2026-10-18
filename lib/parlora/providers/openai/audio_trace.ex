defmodule Parlora.Providers.OpenAI.AudioTrace do
  @moduledoc false
  @limit 64

  def new(now), do: %{origin_us: now, events: [], seen: 0}

  def record(trace, kind, bytes, queue_bytes, now) do
    event = %{at_us: now - trace.origin_us, kind: kind, bytes: bytes, queue_bytes: queue_bytes}
    %{trace | events: Enum.take([event | trace.events], @limit), seen: trace.seen + 1}
  end

  def report(trace, now) do
    %{
      elapsed_us: now - trace.origin_us,
      events_seen: trace.seen,
      truncated: trace.seen > @limit,
      events: Enum.reverse(trace.events)
    }
  end
end
