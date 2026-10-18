defmodule OrderDesk.Speech do
  @moduledoc "Bounded, explicit extraction of three-digit demo IDs and literal delivery text."
  @digits ~w(zero one two three four five six seven eight nine)
  @small @digits ++
           ~w(ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen)
  @tens ~w(twenty thirty forty fifty sixty seventy eighty ninety)
  @words @small ++ @tens ++ ~w(hundred and)
  @nonzero tl(@digits)
  @teens Enum.slice(@small, 10, 10)
  @separator "[ ,\\t-]+"
  @tens_pattern "(?:" <> Enum.join(@tens, "|") <> ")"
  @open_number Regex.compile!(
                 "\\b(?:" <>
                   Enum.join(@nonzero, "|") <>
                   ")" <>
                   @separator <>
                   "(?:hundred(?:" <>
                   @separator <>
                   "and)?(?:" <>
                   @separator <>
                   @tens_pattern <> ")?|" <> @tens_pattern <> ")[ \\t-]*$",
                 "i"
               )

  @spoken_pattern Regex.compile!(
                    "\\b(?:" <>
                      Enum.join(@words, "|") <>
                      ")(?:[ ,\\t-]+(?:" <> Enum.join(@words, "|") <> "))*\\b",
                    "i"
                  )
  @numeric_pattern ~r/\b\d(?:[\t ,]*\d)*\b/u

  # These are valid IDs on their own, but a following word can still change them.
  def open_number?(text), do: open_prefix(text) != nil or incomplete_number?(text)

  defp open_prefix(text) do
    text = normalize_mixed_number(text)
    Regex.run(@open_number, text) || Regex.run(~r/\b[1-9][0-9]0[ \t]*$/, text)
  end

  # One/two digits cannot identify a three-digit order. Do not let a model fill
  # the missing digits from earlier requests while transcription is arriving.
  def incomplete_number?(text) do
    text = text |> normalize_mixed_number() |> String.trim_trailing()

    unless Regex.match?(~r/\b(?:that|this|previous|same|earlier|last) one$/i, text) do
      short_tail?(@spoken_pattern, text, fn words ->
        words |> String.downcase() |> String.split(~r/[ ,\t-]+/) |> number_words()
      end) or short_tail?(@numeric_pattern, text, &String.replace(&1, ~r/\D/u, ""))
    else
      false
    end
  end

  defp short_tail?(pattern, text, convert) do
    case Regex.scan(pattern, text, return: :index) |> List.last() do
      [{offset, size}] when offset + size == byte_size(text) ->
        case convert.(binary_part(text, offset, size)) do
          value when is_binary(value) -> byte_size(value) in 1..2
          _invalid -> false
        end

      _not_a_tail ->
        false
    end
  end

  def completes_number?(handled, fresh) when is_binary(handled) do
    case open_prefix(handled) do
      [prefix] ->
        case {numbers(prefix), numbers(prefix <> fresh)} do
          {[before], [after_number]} -> before != after_number
          _other -> false
        end

      nil ->
        false
    end
  end

  def completes_number?(_handled, _fresh), do: false

  def numbers(text) do
    text = normalize_mixed_number(text)

    numeric =
      Regex.scan(@numeric_pattern, text)
      |> Enum.flat_map(fn [n] -> repeated_numbers(n, &String.replace(&1, ~r/\D/u, "")) end)

    spoken =
      Regex.scan(@spoken_pattern, text)
      |> Enum.flat_map(fn [words] -> repeated_numbers(words, &spoken_number/1) end)

    (numeric ++ spoken) |> Enum.filter(&(is_binary(&1) and byte_size(&1) == 3)) |> Enum.uniq()
  end

  @doc "Rejoin an unfinished number and its leading suffix, preserving following request text."
  def continue_number(prefix, reply) when is_binary(prefix) do
    leading = leading_number(reply)
    combined = prefix <> " " <> String.trim_leading(reply)

    if leading && incomplete_number?(leading) && open_number?(prefix) &&
         match?([_], numbers(combined)), do: combined, else: reply
  end

  def continue_number(_prefix, reply), do: reply

  # Join only supported unfinished cardinal/digit prefixes, never arbitrary turns.
  def join_number_segments(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn segment, acc ->
      case acc do
        [prefix | rest] ->
          joined = continue_number(prefix, segment)
          if joined == segment, do: [segment | acc], else: [joined | rest]

        [] ->
          [segment]
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp leading_number(text) do
    text = String.trim_leading(text)

    Enum.find_value([@spoken_pattern, @numeric_pattern], fn pattern ->
      case Regex.run(pattern, text, return: :index) do
        [{0, size}] -> binary_part(text, 0, size)
        _other -> nil
      end
    end)
  end

  # This recognizes only the completion of an already admitted refusal sentence.
  # A fresh question or instruction following that sentence must still be classified.
  def refusal_continuation?(handled, fresh) when is_binary(handled) and is_binary(fresh) do
    normalize = fn text ->
      text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, " ") |> String.trim()
    end

    prefix = normalize.(handled)
    tail = normalize.(fresh)
    combined = prefix <> " " <> tail

    tail != "" and
      Regex.match?(
        ~r/\A(?:no )?(?:don t|do not) save(?: that| it)?(?: keep the original instructions)?\z/,
        combined
      ) and
      not Regex.match?(
        ~r/\A(?:no )?(?:don t|do not) save(?: that| it)? keep the original instructions\z/,
        prefix
      )
  end

  def refusal_continuation?(_handled, _fresh), do: false

  defp spoken_number(words) do
    words
    |> String.downcase()
    |> String.split(~r/[ ,\t-]+/)
    |> trim_conjunctions()
    |> number_words()
  end

  # First preserve ordinary comma-separated digits. Only if that whole form is
  # invalid, accept a list of complete IDs; never salvage a partial/conflicting tail.
  defp repeated_numbers(text, parse) do
    case parse.(text) do
      id when is_binary(id) and byte_size(id) == 3 ->
        [id]

      _ ->
        parts = String.split(text, ",") |> Enum.map(&String.trim/1)
        ids = Enum.map(parts, parse)
        if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) == 3)), do: ids, else: []
    end
  end

  @doc "One complete number-only reply, including equivalent repeated forms."
  def number_reply(text) do
    words = text |> String.downcase() |> String.trim() |> String.split(~r/[\s,.-]+/, trim: true)

    numeric? =
      words != [] and Enum.all?(words, &(&1 in @words or Regex.match?(~r/\A[0-9]+\z/, &1)))

    case {numeric?, numbers(text), incomplete_number?(text)} do
      {true, [order], false} -> order
      _ -> nil
    end
  end

  @doc "An explicit correction containing only a complete order number, never an edit or cancellation."
  def read_correction(text) do
    correction =
      Regex.run(
        ~r/\A\s*(?:(?:great|oh|sorry)[,.!\s]+|i (?:made|make) a mistake[,.!\s]+)*(?:no[,.\s]+|(?:actually[,.\s]+)?i (?:mean|meant)\s+(?:order\s+)?|actually[,.\s]+(?:order\s+)?|the order number is\s+)(.+?)\s*[.!]?\z/iu,
        text
      ) ||
        Regex.run(~r/\A\s*(?:oh[,.!\s]+)?sorry[,.!\s]+(?:order\s+)?(.+?)\s*[.!]?\z/iu, text)

    case correction do
      [_, number] -> if not open_number?(number), do: number_reply(number)
      _ -> nil
    end
  end

  @doc "One complete, unambiguous number to propose in a clarification, never to execute."
  def clarification_number(text) do
    if not open_number?(text) and not changed_order_reference?(text) do
      case numbers(text) do
        [order] -> order
        _ -> nil
      end
    end
  end

  @doc false
  def number_mentioned?(text),
    do: Regex.match?(@numeric_pattern, text) or Regex.match?(@spoken_pattern, text)

  # ASR may render a cardinal prefix as digits and its continuation as words.
  # Only support the same three-digit cardinal grammar as the spoken parser:
  # 120 three -> 123, 100 twenty three -> 123. Never concatenate extra digits.
  defp normalize_mixed_number(text) do
    pattern = ~r/\b([1-9][0-9]0)[ \t-]+((?:[a-z]+)(?:[ \t-]+[a-z]+)*)/iu

    Regex.replace(pattern, text, fn full, prefix, rest ->
      words = String.downcase(rest) |> String.split(~r/[ \t-]+/)
      {number, trailing} = Enum.split_while(words, &(&1 in @words))
      base = String.to_integer(prefix)
      increment = under_hundred(without_and(number))
      ceiling = if rem(base, 100) == 0, do: 100, else: 10

      if is_integer(increment) and increment > 0 and increment < ceiling do
        # Preserve the original trailing text (including case) after the number.
        count = length(number)
        pieces = String.split(rest, ~r/[ \t-]+/)
        suffix = if trailing == [], do: "", else: " " <> Enum.join(Enum.drop(pieces, count), " ")
        Integer.to_string(base + increment) <> suffix
      else
        full
      end
    end)
  end

  # A conjunction bordering the number belongs to the surrounding request.
  # Keep internal "and" so malformed or multiple groups are not added together.
  defp trim_conjunctions(words) do
    words
    |> Enum.drop_while(&(&1 == "and"))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == "and"))
    |> Enum.reverse()
  end

  defp number_words(words) do
    if Enum.all?(words, &(&1 in @digits)) do
      Enum.map_join(
        words,
        &Integer.to_string(Enum.find_index(@digits, fn word -> word == &1 end))
      )
    else
      grouped_number(words)
    end
  end

  defp grouped_number([digit, "hundred" | tail]) when digit in @nonzero,
    do: combine(digit, without_and(tail))

  defp grouped_number(["hundred" | tail]), do: combine("one", without_and(tail))

  # Spoken IDs can group the last two digits: "one twenty three" -> 123.
  defp grouped_number([digit, tens | tail]) when digit in @nonzero and tens in @tens,
    do: combine(digit, [tens | tail])

  defp grouped_number([digit, teen]) when digit in @nonzero and teen in @teens,
    do: combine(digit, [teen])

  defp grouped_number(words) do
    case without_and(words) do
      [] ->
        nil

      digits ->
        case under_hundred(digits) do
          nil -> nil
          number -> Integer.to_string(number)
        end
    end
  end

  defp without_and(["and" | tail]), do: tail
  defp without_and(tail), do: tail

  defp combine(digit, tail) do
    case under_hundred(tail) do
      nil -> nil
      value -> Integer.to_string(Enum.find_index(@digits, &(&1 == digit)) * 100 + value)
    end
  end

  defp under_hundred([]), do: 0
  defp under_hundred([word]) when word in @small, do: Enum.find_index(@small, &(&1 == word))
  defp under_hundred([word]) when word in @tens, do: tens_value(word)

  defp under_hundred([tens, digit]) when tens in @tens and digit in @nonzero,
    do: tens_value(tens) + Enum.find_index(@digits, &(&1 == digit))

  defp under_hundred(_words), do: nil
  defp tens_value(word), do: (Enum.find_index(@tens, &(&1 == word)) + 2) * 10

  # This is a narrow no-work fast path, not a general intent classifier. Match the
  # whole caller segment so "thanks, but check 123" still reaches interpretation.
  def social?(text) do
    Regex.match?(
      ~r/\A\s*(?:(?:okay|ok|thanks|thank you|bye|goodbye|let me check|let me see|one moment|just a moment)[\s,.!—-]*)+\z/iu,
      text
    )
  end

  # Conservative guard for clarification wording, not order selection. A request
  # pointing away from the current order must not be clarified as though it stayed.
  def changed_order_reference?(text) do
    Regex.match?(
      ~r/\b(?:(?:another|different|other|new|previous|earlier|first|second)\s+(?:order|one|purchase)|(?:wrong|which)\s+order|not\b|go\s+back|switch\b|changed?\s+my\s+mind)/iu,
      text
    )
  end

  # "let/live with/at/in/on" is accepted only as literal draft text after the policy
  # classifies a delivery edit. Preserve the words for review; never silently
  # rewrite the caller's destination or treat a draft as permission to save.
  # ASR ellipses indicate a pause within a destination, not a sentence boundary.
  # Preserve the literal text for review, and reject overlong text rather than
  # silently constructing a draft from a truncated destination.
  def delivery(text) do
    case Regex.scan(
           ~r/\b(?:leave|left|deliver|put|hand|(?:let|live)(?=\s+(?:with|at|in|on)\b))\s+(?:(?:it|the package|the parcel|my package)\s+|(?=(?:at|in|on|with|by|to|outside|inside|behind|under|near|beside)\s+))(?:\.{2,}|[^.!?\n])+/iu,
           text
         )
         |> List.last() do
      [literal] ->
        literal = String.trim(literal)

        if String.length(literal) > 260 or
             Regex.match?(~r/\b(?:at|in|on|with|by|to|the|a|an|my|and|or)\s*$/iu, literal) or
             Regex.match?(~r/\b(?:my|your)\s+(?:front|back|side)\s*$/iu, literal),
           do: nil,
           else: literal

      nil ->
        nil
    end
  end
end
