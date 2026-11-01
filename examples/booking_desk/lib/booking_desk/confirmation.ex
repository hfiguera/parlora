defmodule BookingDesk.Confirmation do
  @moduledoc "Compare a verified hexadecimal confirmation with its spoken caption spelling."
  @words %{
    "zero" => "0",
    "oh" => "0",
    "o" => "0",
    "one" => "1",
    "two" => "2",
    "three" => "3",
    "four" => "4",
    "five" => "5",
    "six" => "6",
    "seven" => "7",
    "eight" => "8",
    "nine" => "9",
    "ay" => "A",
    "bee" => "B",
    "see" => "C",
    "dee" => "D",
    "ee" => "E",
    "eff" => "F",
    "dash" => "",
    "hyphen" => ""
  }
  @tens %{
    "twenty" => 20,
    "thirty" => 30,
    "forty" => 40,
    "fifty" => 50,
    "sixty" => 60,
    "seventy" => 70,
    "eighty" => 80,
    "ninety" => 90
  }
  @teens Enum.zip(
           ~w(ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen),
           10..19
         )
         |> Map.new()

  def complete?(text, code) when is_binary(text) and is_binary(code) do
    Regex.match?(~r/^BD-[0-9A-F]{8}$/, code) and
      String.contains?(normalize(text), String.replace(code, "-", ""))
  end

  def complete?(_, _), do: false

  defp normalize(text) do
    text =
      Regex.replace(~r/\b([A-F]|ay|bee|see|dee|ee|eff)\s+as\s+in\s+([a-z]+)\b/i, text, fn whole,
                                                                                          token,
                                                                                          example ->
        letter = Map.get(@words, String.downcase(token), String.upcase(token))
        if String.upcase(String.first(example)) == letter, do: letter, else: whole
      end)

    text =
      Regex.replace(
        ~r/\b(#{Enum.join(Map.keys(@tens), "|")})(?:[ -]+(one|two|three|four|five|six|seven|eight|nine))?\b/i,
        text,
        fn _, ten, one ->
          Integer.to_string(
            @tens[String.downcase(ten)] +
              if(one == "", do: 0, else: String.to_integer(@words[String.downcase(one)]))
          )
        end
      )

    words =
      Map.merge(
        @words,
        Map.new(@teens, fn {word, number} -> {word, Integer.to_string(number)} end)
      )

    text =
      Regex.replace(~r/\b(#{Enum.join(Map.keys(words), "|")})\b/i, text, fn word ->
        words[String.downcase(word)]
      end)

    text |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "")
  end
end
