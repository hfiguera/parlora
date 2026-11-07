defmodule BookingDesk.CallGuard.Announcement do
  @moduledoc "Conservative caption and subsequent playout evidence for the intended guard message."

  def new(reason, expected, generation, started) do
    %{
      token: make_ref(),
      reason: reason,
      generation: generation,
      expected: Enum.map(List.wrap(expected), &normalize/1),
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
        caption: matches?(announcement, normalize(text))
    }
  end

  def caption(announcement, _), do: announcement

  def reset(announcement),
    do: %{announcement | text: "", segment: nil, caption: false, heard: false}

  def audible(%{first_voice: first} = announcement, at),
    do: %{announcement | first_voice: first || at, last_voice: at, heard: true}

  def audible(announcement, at),
    do: %{announcement | heard: announcement.heard or announcement.caption, last_voice: at}

  @scope_refusal ~r/\A(?:i am just the scheduling desk here at cedarwood family clinic so )?(?:i cannot help with|i am not able to help with) (?<topic>.+?)(?: questions)? but (?<offer>.+)\z/u
  @clinic_offer ~r/\A(?:i (?:can|would be happy to|d be happy to) (?:help with|assist with|schedule) (?:clinic )?appointments(?: (?:and |or )?(?:registration|insurance(?: details)?|reminders|handle registration))* what (?:appointment help do you need|would you like to arrange)|if you need to book an appointment or anything clinic related i am happy to help with that)\z/u

  def scope_redirect?(%{caption: true}, _caller), do: true

  def scope_redirect?(%{text: text}, caller) do
    with %{"topic" => topic, "offer" => offer} <-
           Regex.named_captures(@scope_refusal, normalize(text)) do
      String.contains?(" #{normalize(caller)} ", " #{topic} ") and
        Regex.match?(@clinic_offer, offer)
    else
      nil -> false
    end
  end

  defp matches?(%{reason: reason, expected: expected}, text)
       when reason in [:scope_redirect, :scope_close],
       do:
         text in expected or
           Regex.replace(~r/\A(?:(?:okay|sure|mm|hmm|right) ){1,2}/u, text, "") in expected

  defp matches?(%{expected: expected}, text), do: text in expected

  defp normalize(text),
    do:
      text
      |> String.downcase()
      |> String.replace(["[sigh]", "[breath]"], " ")
      |> String.replace(~r/\bcan['’]t\b/u, "cannot")
      |> String.replace(~r/\bi['’]m\b/u, "i am")
      |> String.replace(~r/\b(?:nine one one|9 1 1)\b/u, "911")
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.trim()
end
