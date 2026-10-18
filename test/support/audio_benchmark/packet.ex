defmodule Parlora.TestSupport.AudioBenchmark.Packet do
  @moduledoc false
  alias Parlora.AudioQueue

  # Model the browser's staging separately from the 10 ms render clock. A queue
  # fragment is not a packet; only the final partial packet receives padding.
  defstruct pcm: <<>>, source?: false, segments: []

  def take(buffer, queue, playout, policy, budget, now) do
    {buffer, queue, playout} = fill(buffer, queue, playout, policy, budget, now)
    bytes = min(480, byte_size(buffer.pcm))
    <<pcm::binary-size(^bytes), rest::binary>> = buffer.pcm
    raw = if buffer.source?, do: pcm, else: <<>>

    age =
      case buffer.segments do
        [{_, at} | _] -> now - at
        [] -> 0
      end

    segments = consume(buffer.segments, byte_size(raw))
    rendered = pcm <> :binary.copy(<<0>>, 480 - bytes)
    {rendered, raw, age, queue, playout, %{buffer | pcm: rest, segments: segments}}
  end

  defp fill(%{pcm: pcm} = buffer, queue, playout, _policy, _budget, _now)
       when byte_size(pcm) >= 480 or (byte_size(pcm) > 0 and queue.bytes == 0),
       do: {buffer, queue, playout}

  defp fill(buffer, queue, playout, policy, budget, now) do
    {pcm, rest, next} = policy.take(playout, queue, budget, now)
    source? = next.source_bytes > playout.source_bytes

    segments =
      if source? do
        {frames, _} = AudioQueue.pop(queue, budget)
        buffer.segments ++ Enum.map(frames, &{byte_size(&1.data), &1.timestamp_us})
      else
        []
      end

    buffer = %{buffer | pcm: buffer.pcm <> pcm, source?: source?, segments: segments}
    fill(buffer, rest, next, policy, budget, now)
  end

  defp consume(segments, 0), do: segments

  defp consume([{bytes, at} | rest], count) when bytes > count,
    do: [{bytes - count, at} | rest]

  defp consume([{bytes, _} | rest], count), do: consume(rest, count - bytes)
end
