defmodule BookingDesk.BirthDate do
  @moduledoc "Deterministically verify the LLM-selected DOB evidence, never extract a patient identity."
  @months ~w(january february march april may june july august september october november december)
  @ones ~w(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen)
  @ordinals ~w(first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth)

  def parse(text) when is_binary(text) do
    text = text |> String.downcase() |> String.replace(~r/[’]/u, "'")
    # Verify both spoken date orders after the LLM has selected the excerpts.
    day_first = ~r/^\s*(?:the\s+)?(.+?)\s+(?:of\s+)?(#{Enum.join(@months, "|")})[,\s]+(.+)$/i

    text =
      case Regex.run(day_first, text) do
        [_, day, month, year] -> month <> " " <> day <> " " <> year
        _ -> text
      end

    pattern = ~r/\b(#{Enum.join(@months, "|")})\s+(?:the\s+)?(.+)$/i

    case Regex.run(pattern, text) do
      [_, month, rest] ->
        words =
          rest
          |> String.replace(~r/(\d+)(st|nd|rd|th)\b/, "\\1")
          |> String.replace(~r/[^a-z0-9 ]/, " ")
          |> String.split()

        with {:ok, day, year_words} <- day(words),
             {:ok, year} <- year(year_words),
             {:ok, date} <- Date.new(year, Enum.find_index(@months, &(&1 == month)) + 1, day) do
          {:ok, Date.to_iso8601(date)}
        else
          _ -> :error
        end

      _ ->
        value = String.trim(text)

        iso =
          case String.split(value, "/") do
            [m, d, y] ->
              y <> "-" <> String.pad_leading(m, 2, "0") <> "-" <> String.pad_leading(d, 2, "0")

            _ ->
              value
          end

        case Date.from_iso8601(iso) do
          {:ok, date} -> {:ok, Date.to_iso8601(date)}
          _ -> :error
        end
    end
  end

  defp day([word | rest]) do
    cond do
      Regex.match?(~r/^\d{1,2}$/, word) ->
        {:ok, String.to_integer(word), rest}

      word in @ordinals ->
        {:ok, Enum.find_index(@ordinals, &(&1 == word)) + 1, rest}

      word in ["twenty", "thirty"] ->
        base = if word == "twenty", do: 20, else: 30

        case rest do
          [one | tail]
          when one in [
                 "first",
                 "second",
                 "third",
                 "fourth",
                 "fifth",
                 "sixth",
                 "seventh",
                 "eighth",
                 "ninth"
               ] ->
            {:ok, base + Enum.find_index(@ordinals, &(&1 == one)) + 1, tail}

          [one | tail]
          when one in ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"] ->
            {:ok, base + Enum.find_index(@ones, &(&1 == one)), tail}

          _ ->
            {:ok, base, rest}
        end

      word in ["twentieth", "thirtieth"] ->
        {:ok, if(word == "twentieth", do: 20, else: 30), rest}

      word in @ones ->
        {:ok, Enum.find_index(@ones, &(&1 == word)), rest}

      true ->
        :incomplete
    end
  end

  defp day(_), do: :incomplete

  defp year([number]) do
    case Integer.parse(number) do
      {value, ""} when value >= 1900 and value <= 2026 -> {:ok, value}
      _ -> :incomplete
    end
  end

  defp year(["nineteen" | rest]), do: two_digits(rest, 1900)
  defp year(["twenty" | rest]), do: two_digits(rest, 2000)
  defp year(["two", "thousand" | rest]), do: two_digits(Enum.reject(rest, &(&1 == "and")), 2000)
  defp year(_), do: :incomplete

  defp two_digits(words, base) do
    tens = %{
      "twenty" => 20,
      "thirty" => 30,
      "forty" => 40,
      "fifty" => 50,
      "sixty" => 60,
      "seventy" => 70,
      "eighty" => 80,
      "ninety" => 90
    }

    value =
      case words do
        [] ->
          0

        [word] ->
          Map.get(tens, word, Enum.find_index(@ones, &(&1 == word)))

        [ten, one] ->
          if Map.has_key?(tens, ten) and one in Enum.take(@ones, 10),
            do: tens[ten] + Enum.find_index(@ones, &(&1 == one))

        _ ->
          nil
      end

    if is_integer(value) and base + value <= 2026, do: {:ok, base + value}, else: :incomplete
  end
end
