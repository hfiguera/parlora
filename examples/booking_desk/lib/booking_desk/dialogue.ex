defmodule BookingDesk.Dialogue do
  @moduledoc "Application dialogue assembled from duplex transcript fragments."

  # GPT Live captions use 200 ms intervals. Allow at most three intervals of
  # caller silence across an overlapping assistant fragment, not a whole reply.
  @continuation_gap_ms 600

  def build(transcripts, opts \\ []) do
    cursor = Keyword.get(opts, :after_cursor)

    transcripts
    |> Enum.reverse()
    # An admitted request is also a caller boundary. Untimed providers may send
    # the next question without an intervening assistant transcript.
    |> Enum.chunk_by(&{&1.speaker, request_side(&1, cursor)})
    |> Enum.map(&run(&1, cursor))
    |> Enum.reduce([], &append/2)
    # Assistant acknowledgments after the latest caller cannot change its intent.
    |> Enum.drop_while(&(&1.speaker == :assistant))
    |> Enum.take(10)
    |> Enum.reverse()
    |> Enum.map(&Map.take(&1, [:speaker, :text]))
  end

  defp request_side(%{speaker: :user} = part, cursor) when is_integer(cursor),
    do: Map.get(part, :arrival_order, 0) > cursor

  defp request_side(_, _), do: nil

  defp run(parts, cursor) do
    generations = Enum.map(parts, &Map.get(&1, :provider_generation)) |> Enum.uniq()

    timed? =
      length(generations) == 1 and hd(generations) != nil and
        Enum.all?(parts, fn part ->
          first = Map.get(part, :start_ms)
          last = Map.get(part, :end_ms)
          is_number(first) and is_number(last) and first >= 0 and last >= first
        end)

    %{
      speaker: hd(parts).speaker,
      request_side: request_side(hd(parts), cursor),
      text: Enum.map_join(parts, & &1.delta),
      generation: if(timed?, do: hd(generations)),
      start_ms: if(timed?, do: Enum.min_by(parts, & &1.start_ms).start_ms),
      end_ms: if(timed?, do: Enum.max_by(parts, & &1.end_ms).end_ms)
    }
  end

  defp append(
         %{speaker: :user} = next,
         [
           %{speaker: :assistant} = overlap,
           %{speaker: :user} = previous | rest
         ] = runs
       ) do
    if continuation?(previous, overlap, next) do
      # Preserve the assistant's words after the complete caller utterance.
      # They remain historical context once a later caller turn arrives.
      [overlap, %{previous | text: previous.text <> next.text, end_ms: next.end_ms} | rest]
    else
      [next | runs]
    end
  end

  defp append(next, [%{speaker: speaker} = previous | rest])
       when next.speaker == speaker and next.request_side == previous.request_side do
    timed? = previous.generation != nil and previous.generation == next.generation

    [
      %{
        previous
        | text: previous.text <> next.text,
          generation: if(timed?, do: previous.generation),
          start_ms: if(timed?, do: min(previous.start_ms, next.start_ms)),
          end_ms: if(timed?, do: max(previous.end_ms, next.end_ms))
      }
      | rest
    ]
  end

  defp append(next, runs), do: [next | runs]

  defp continuation?(previous, overlap, next) do
    previous.request_side == next.request_side and
      previous.generation != nil and previous.generation == next.generation and
      overlap.generation == next.generation and
      next.start_ms >= previous.end_ms and
      next.start_ms - previous.end_ms <= @continuation_gap_ms and
      overlap.start_ms <= next.start_ms and overlap.end_ms >= next.start_ms and
      not Regex.match?(~r/[.!?]\s*$/, previous.text) and
      not String.contains?(overlap.text, "?")
  end
end
