defmodule BookingDesk.Identity do
  @moduledoc "Validate structured demographic extraction; only the database can match a patient."
  @fields ~w(status full_name dob name_evidence dob_evidence)

  def requested?(text),
    do:
      Regex.match?(~r/\bname\b/i, text) and
        Regex.match?(~r/\b(?:date of birth|birth ?date|birthday|dob)\b/i, text)

  def requested_in?(dialogue),
    do: Enum.any?(dialogue, &(&1.speaker == :assistant and requested?(&1.text)))

  def validate(output, state) when is_map(output) do
    source =
      state.dialogue
      |> Enum.filter(&(&1.speaker == :user))
      |> Enum.map_join(" ", & &1.text)
      |> normalize()

    with true <- Enum.sort(Map.keys(output)) == Enum.sort(@fields),
         true <- output["status"] in ["complete", "incomplete", "ambiguous"],
         true <-
           nullable_string?(output["full_name"]) and nullable_string?(output["dob"]) and
             nullable_string?(output["name_evidence"]),
         true <-
           is_list(output["dob_evidence"]) and length(output["dob_evidence"]) <= 4 and
             Enum.all?(output["dob_evidence"], &(is_binary(&1) and byte_size(&1) <= 256)),
         true <-
           supported?(output["name_evidence"], source) and
             Enum.all?(output["dob_evidence"], &supported?(&1, source)) do
      validate_fields(output)
    else
      _ -> {:error, :invalid_extraction}
    end
  end

  def validate(_, _), do: {:error, :invalid_extraction}

  defp validate_fields(%{"status" => "ambiguous"}), do: {:incomplete, [:ambiguous]}

  defp validate_fields(%{"status" => "incomplete"} = output) do
    missing =
      Enum.filter([:name, :dob], fn
        :name -> output["full_name"] == nil
        :dob -> output["dob"] == nil
      end)

    {:incomplete, if(missing == [], do: [:ambiguous], else: missing)}
  end

  defp validate_fields(output) do
    with name when is_binary(name) <- output["full_name"],
         evidence when is_binary(evidence) <- output["name_evidence"],
         name = normalize(name),
         true <-
           name == normalize(evidence) and byte_size(name) <= 100 and
             Regex.match?(~r/^[\p{L}][\p{L}\p{M}'-]*(?:\s+[\p{L}][\p{L}\p{M}'-]*){1,7}$/u, name),
         dob when is_binary(dob) <- output["dob"],
         {:ok, date} <- Date.from_iso8601(dob),
         true <- date.year >= 1900 and Date.compare(date, ~D[2026-11-02]) != :gt,
         {:ok, ^dob} <- BookingDesk.BirthDate.parse(Enum.join(output["dob_evidence"], " ")) do
      {:ok, %{name: name, dob: dob}}
    else
      _ -> {:error, :invalid_extraction}
    end
  end

  defp normalize(text),
    do:
      text
      |> String.normalize(:nfc)
      |> String.downcase()
      |> String.replace("’", "'")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

  defp supported?(nil, _), do: true

  defp supported?(text, source),
    do: String.trim(text) != "" and String.contains?(source, normalize(text))

  defp nullable_string?(nil), do: true
  defp nullable_string?(s), do: is_binary(s) and byte_size(s) <= 256
end
