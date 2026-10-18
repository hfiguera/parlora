defmodule OrderDesk.CallerHistory do
  @moduledoc "Revisable caller segments; preserves deltas within overlapping conversation."

  # Punctuation is preserved in text, but does not constitute new caller intent.
  def revision(transcripts) do
    transcripts
    |> Enum.find(fn fragment ->
      fragment.speaker == :user and Regex.match?(~r/[^\s\p{P}]/u, fragment.delta)
    end)
    |> then(&if(&1, do: Map.get(&1, :arrival_order, 0), else: 0))
  end

  def text(transcripts) do
    {parts, _previous, _between} =
      transcripts
      |> Enum.reverse()
      |> Enum.reduce({[], nil, []}, &append/2)

    parts |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # Keep assistant answers alongside caller questions. A task admission is not a
  # conversation cursor: later progress questions can already have been answered.
  # These are speaker runs, not authoritative turns; backchannels remain visible.
  def dialogue(transcripts) do
    transcripts
    |> Enum.reverse()
    |> Enum.chunk_by(& &1.speaker)
    |> Enum.take(-8)
    |> Enum.map(fn [first | _] = fragments ->
      %{
        speaker: first.speaker,
        text: fragments |> Enum.map_join(& &1.delta) |> String.slice(-512, 512)
      }
    end)
  end

  # Untimed Gemini history has no newline separators to split on. Its latest
  # speaker run is context, not an authoritative turn or a timing claim. Timed
  # providers retain the existing overlap-aware segmentation.
  def latest(transcripts) do
    case Enum.find(transcripts, &(&1.speaker == :user)) do
      %{timing: :unavailable} -> latest_run(transcripts)
      _ -> transcripts |> text() |> String.split("\n") |> List.last()
    end
    |> String.slice(-4_000, 4_000)
  end

  defp latest_run(transcripts) do
    transcripts
    |> Enum.drop_while(&(&1.speaker != :user))
    |> Enum.take_while(&(&1.speaker == :user))
    |> Enum.reverse()
    |> Enum.map_join(& &1.delta)
  end

  defp append(%{speaker: :user} = current, {parts, previous, between}) do
    separated? = previous != nil and Enum.any?(between, &separates?(&1, previous, current))
    parts = if separated?, do: ["\n" | parts], else: parts
    {[current.delta | parts], current, []}
  end

  defp append(%{speaker: :assistant} = fragment, {parts, previous, between}),
    do: {parts, previous, [fragment | between]}

  defp append(_fragment, state), do: state

  # GPT-Live has no authoritative turn boundaries. An intervening assistant interval
  # separates segments only when it does not overlap either caller fragment. Never
  # insert spaces between adjacent deltas: a word or number may span several deltas.
  defp separates?(%{timing: :unavailable}, _previous, _current), do: false

  defp separates?(%{start_ms: start, end_ms: stop}, %{end_ms: left}, %{start_ms: right})
       when is_number(start) and is_number(stop) and is_number(left) and is_number(right),
       do: start >= left and stop <= right

  defp separates?(_assistant, _previous, _current), do: true
end
