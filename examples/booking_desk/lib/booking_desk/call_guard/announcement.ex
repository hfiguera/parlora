defmodule BookingDesk.CallGuard.Announcement do
  @moduledoc "Conservative caption and subsequent playout evidence for the intended guard message."

  def new(reason, expected, generation, started) do
    %{
      token: make_ref(),
      reason: reason,
      generation: generation,
      expected: normalize(expected),
      segment: nil,
      text: "",
      started: started,
      last_voice: started,
      heard: false,
      caption: false
    }
  end

  def caption(announcement, %{generation: generation, payload: part})
      when generation == announcement.generation or is_nil(generation) do
    segment = Map.get(part, :segment_id)

    announcement =
      if segment != announcement.segment, do: reset(announcement), else: announcement

    text = String.slice(announcement.text <> part.delta, -2_000, 2_000)

    %{
      announcement
      | text: text,
        segment: segment,
        caption: normalize(text) == announcement.expected
    }
  end

  def caption(announcement, _), do: announcement

  def reset(announcement),
    do: %{announcement | text: "", segment: nil, caption: false, heard: false}

  def audible(announcement, at),
    do: %{announcement | heard: announcement.heard or announcement.caption, last_voice: at}

  defp normalize(text),
    do:
      text
      |> String.downcase()
      |> String.replace(~r/\bcan['’]t\b/u, "cannot")
      |> String.replace(~r/\b(?:nine one one|9 1 1)\b/u, "911")
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.trim()
end
