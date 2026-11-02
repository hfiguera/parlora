defmodule BookingDesk.Clinicians do
  @moduledoc "Canonical clinic doctors and explicitly supported speech-transcription spellings."
  @names %{"lee" => "Dr. Lee", "patel" => "Dr. Patel"}
  @speech_aliases %{"li" => "lee"}

  def names, do: @names

  def choices do
    doctors =
      Map.new(@names, fn {canonical, name} ->
        spellings =
          for {spelling, ^canonical} <- @speech_aliases,
              do: "Dr. #{String.capitalize(spelling)}"

        label =
          if spellings == [],
            do: name,
            else: "#{name}, also transcribed as #{Enum.join(spellings, ", ")} in speech"

        {canonical, label}
      end)

    Map.merge(doctors, %{
      "any" => "The caller explicitly has no doctor preference",
      "unknown" => "Missing, unlisted, conflicting or uncertain doctor preference"
    })
  end

  def guidance do
    "The clinic roster is Dr. Lee and Dr. Patel. Dr. Li is an approved speech-transcription spelling of the same spoken name as Dr. Lee; select the canonical choice lee for either spelling. Use only caller evidence. An explicit spelling correction, rejection or contrast between names overrides this alias and requires clarification. Unlisted names and ambiguous preferences remain unknown; never default a missing preference to Dr. Lee."
  end

  def canonical(value) when value in ["lee", "patel", "any", "unknown"], do: value
  def canonical(value), do: Map.get(@speech_aliases, value, "unknown")

  def normalize(%{"clinician" => value} = fields),
    do: Map.put(fields, "clinician", canonical(value))

  def normalize(fields), do: fields
end
