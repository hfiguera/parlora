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
    retained = Map.get(state, :retained_identity, %{})

    source =
      state.dialogue
      |> Enum.filter(&(&1.speaker == :user))
      |> Enum.map_join(" ", & &1.text)
      |> Kernel.<>(" " <> Enum.join(Map.get(state, :retained_registration, []), " "))
      |> Kernel.<>(" " <> retained_source(retained))
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
      validate_fields(output, state, retained)
    else
      _ -> {:error, :invalid_extraction}
    end
  end

  def validate(_, _), do: {:error, :invalid_extraction}

  defp validate_fields(%{"status" => "ambiguous"}, _, _), do: {:incomplete, [:ambiguous]}

  defp validate_fields(output, state, retained) do
    changed =
      is_binary(output["full_name"]) and retained[:name] != nil and
        normalize(output["full_name"]) != retained.name

    output = isolate_person(output, state, changed)
    retained = if changed, do: %{}, else: retained

    retained =
      if output["dob"] == nil and output["dob_evidence"] != [],
        do: Map.delete(retained, :dob),
        else: retained

    with {:ok, name} <- name_fields(output),
         {:ok, dob} <- dob_fields(output) do
      fields = retained |> Map.merge(name) |> Map.merge(dob)
      finish_fields(output["status"], fields, changed)
    end
  end

  defp isolate_person(output, state, true) do
    source = normalize(state.latest_user)

    fresh =
      output["dob_evidence"] != [] and
        Enum.all?(output["dob_evidence"], &supported?(&1, source))

    if fresh, do: output, else: Map.merge(output, %{"dob" => nil, "dob_evidence" => []})
  end

  defp isolate_person(output, _, false), do: output

  defp name_fields(%{"full_name" => nil, "name_evidence" => nil}), do: {:ok, %{}}

  defp name_fields(%{"full_name" => name, "name_evidence" => evidence})
       when is_binary(name) and is_binary(evidence) do
    value = normalize(name)

    if value == normalize(evidence) and byte_size(value) <= 100 and
         Regex.match?(~r/^[\p{L}][\p{L}\p{M}'-]*(?:\s+[\p{L}][\p{L}\p{M}'-]*){1,7}$/u, value),
       do: {:ok, %{name: value, name_evidence: evidence}},
       else: {:error, :invalid_extraction}
  end

  defp name_fields(_), do: {:error, :invalid_extraction}

  defp dob_fields(%{"dob" => nil, "dob_evidence" => []}), do: {:ok, %{}}
  defp dob_fields(%{"dob" => nil, "dob_evidence" => parts}), do: {:ok, %{dob_evidence: parts}}

  defp dob_fields(%{"dob" => dob, "dob_evidence" => parts}) when is_binary(dob) do
    with {:ok, date} <- Date.from_iso8601(dob),
         true <- date.year >= 1900 and Date.compare(date, ~D[2026-11-02]) != :gt,
         {:ok, ^dob} <- BookingDesk.BirthDate.parse(Enum.join(parts, " ")) do
      {:ok, %{dob: dob, dob_evidence: parts}}
    else
      _ -> {:error, :invalid_extraction}
    end
  end

  defp dob_fields(_), do: {:error, :invalid_extraction}

  defp finish_fields(status, fields, changed) do
    missing = Enum.reject([:name, :dob], &Map.has_key?(fields, &1))

    case {status, missing, changed} do
      {"complete", [], _} -> {:ok, Map.take(fields, [:name, :dob])}
      {"complete", _, false} -> {:error, :invalid_extraction}
      _ -> {:incomplete, if(missing == [], do: [:ambiguous], else: missing), fields}
    end
  end

  defp retained_source(retained) do
    ([retained[:name_evidence] || retained[:name], retained[:dob]] ++
       Map.get(retained, :dob_evidence, []))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
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
