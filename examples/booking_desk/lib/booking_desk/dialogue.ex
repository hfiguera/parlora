defmodule BookingDesk.Dialogue do
  @moduledoc "Application dialogue assembled from duplex transcript fragments."

  # GPT Live captions use 200 ms intervals. Allow at most three intervals of
  # caller silence across an overlapping assistant fragment, not a whole reply.
  @continuation_gap_ms 600

  def build(transcripts, opts \\ []) do
    cursor = Keyword.get(opts, :after_cursor)
    limit = Keyword.get(opts, :limit, 10)

    fields =
      if Keyword.get(opts, :with_cursor, false),
        do: [:speaker, :text, :first_cursor],
        else: [:speaker, :text]

    transcripts
    |> Enum.reverse()
    |> order_overlaps()
    # An admitted request is also a caller boundary. Untimed providers may send
    # the next question without an intervening assistant transcript.
    |> Enum.chunk_by(&{&1.speaker, request_side(&1, cursor), speech_boundary(&1)})
    |> Enum.map(&run(&1, cursor))
    |> Enum.reduce([], &append/2)
    # Assistant acknowledgments after the latest caller cannot change its intent.
    |> Enum.drop_while(
      &(not Keyword.get(opts, :include_assistant_reply, false) and &1.speaker == :assistant)
    )
    |> Enum.take(limit)
    |> Enum.reverse()
    |> Enum.map(&Map.take(&1, fields))
  end

  defp request_side(%{speaker: :user} = part, cursor) when is_integer(cursor),
    do: Map.get(part, :arrival_order, 0) > cursor

  defp request_side(_, _), do: nil

  defp speech_boundary(part),
    do: {Map.get(part, :provider_generation), Map.get(part, :segment_id)}

  defp run(parts, cursor) do
    generation =
      case Enum.map(parts, &Map.get(&1, :provider_generation)) |> Enum.uniq() do
        [generation] -> generation
        _ -> nil
      end

    timed? =
      generation != nil and
        Enum.all?(parts, &valid_interval?/1)

    %{
      speaker: hd(parts).speaker,
      first_cursor: Map.get(hd(parts), :arrival_order, 0),
      request_side: request_side(hd(parts), cursor),
      speech_boundary: speech_boundary(hd(parts)),
      text: Enum.map_join(parts, & &1.delta),
      generation: if(timed?, do: generation),
      start_ms: if(timed?, do: Enum.min_by(parts, & &1.start_ms).start_ms),
      end_ms: if(timed?, do: Enum.max_by(parts, & &1.end_ms).end_ms)
    }
  end

  defp valid_interval?(part) do
    first = Map.get(part, :start_ms)
    last = Map.get(part, :end_ms)
    is_number(first) and is_number(last) and first >= 0 and last >= first
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
       when next.speaker == speaker and next.request_side == previous.request_side and
              next.speech_boundary == previous.speech_boundary do
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
    same_context?(previous, overlap, next) and
      nearby?(previous, next) and
      overlap.start_ms <= next.start_ms and overlap.end_ms >= next.start_ms and
      not Regex.match?(~r/[.!?]\s*$/, previous.text) and
      not String.contains?(overlap.text, "?")
  end

  defp same_context?(previous, overlap, next),
    do:
      previous.request_side == next.request_side and previous.generation != nil and
        previous.generation == next.generation and overlap.generation == next.generation

  defp nearby?(previous, next),
    do:
      next.start_ms >= previous.end_ms and next.start_ms - previous.end_ms <= @continuation_gap_ms

  # A native acknowledgment may interleave untimed words in one caller turn.
  # Keep every assistant word after that complete turn; it cannot authorize the
  # caller's answer to a question which was asked before the turn began.
  defp order_overlaps(parts) do
    indexed = Enum.with_index(parts)

    caller_ends =
      Map.new(
        for {%{speaker: :user, segment_id: id} = part, index} <- indexed,
            is_binary(id),
            do: {speech_boundary(part), index}
      )

    indexed
    |> Enum.sort_by(fn {part, index} ->
      target = overlap_end(part, caller_ends, index)
      {target, if(target > index, do: 1, else: 0), index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp overlap_end(%{speaker: :assistant, overlaps_user_segment_id: id} = part, ends, index)
       when is_binary(id),
       do: max(index, Map.get(ends, {Map.get(part, :provider_generation), id}, index))

  defp overlap_end(_, _, index), do: index
end
