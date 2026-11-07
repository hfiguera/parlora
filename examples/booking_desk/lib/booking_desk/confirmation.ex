defmodule BookingDesk.Confirmation do
  @moduledoc "Compare a verified hexadecimal confirmation with its spoken caption spelling."
  alias BookingDesk.{Policy, ReadbackScope, Store}

  @alphabet %{
    "A" => "A as in Alpha",
    "B" => "B as in Bravo",
    "C" => "C as in Charlie",
    "D" => "D as in Delta",
    "E" => "E as in Echo",
    "F" => "F as in Foxtrot",
    "0" => "zero",
    "1" => "one",
    "2" => "two",
    "3" => "three",
    "4" => "four",
    "5" => "five",
    "6" => "six",
    "7" => "seven",
    "8" => "eight",
    "9" => "nine",
    "-" => "dash"
  }
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
    "niner" => "9",
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

  def spoken(code) when is_binary(code) do
    if Regex.match?(~r/^BD-[0-9A-F]{8}$/, code),
      do: code |> String.graphemes() |> Enum.map_join(", ", &Map.fetch!(@alphabet, &1))
  end

  def spoken(_), do: nil

  def current(snapshot, task, store \\ Store)

  def current(
        snapshot,
        %{
          status: status,
          input: %{operation: "confirm", lookup_request: lookup},
          request_ids: [request | _]
        },
        store
      )
      when status in [:submitted, :completed] do
    with %{lookup_request: ^lookup} <- Policy.identity(snapshot, store),
         %{kind: "booking", status: "booked", confirmation: code} = appointment <-
           Store.appointment(request, lookup, snapshot.session_id, store),
         readout when is_binary(readout) <- spoken(code) do
      reminder = Store.reminder(request, lookup, snapshot.session_id, store)

      Map.merge(appointment, %{
        request_id: request,
        readout: readout,
        reminder_status: if(reminder, do: reminder.status)
      })
    else
      _ -> nil
    end
  end

  def current(_, _, _), do: nil

  def correction(
        snapshot,
        %{request_id: request} = current,
        %{request_ids: [request | _]} = task,
        cursor
      ) do
    turns =
      ReadbackScope.turns(snapshot, request, :confirmation_readback,
        include_assistant_reply: true
      )

    case List.last(turns) do
      %{speaker: :assistant, first_cursor: first, text: text} when first > cursor ->
        previous = ReadbackScope.current(snapshot, request, :confirmation_readback)[:attempt] || 0

        already_read =
          Enum.any?(
            Enum.drop(turns, -1),
            &(&1.speaker == :assistant and complete?(&1.text, current.confirmation))
          )

        if previous < 2 and announced?(text, already_read) and
             not complete?(text, current.confirmation) do
          {correction_message(current, text),
           ReadbackScope.input(snapshot, task, :confirmation_readback, previous + 1)}
        end

      _ ->
        nil
    end
  end

  def correction(_, _, _, _), do: nil

  defp correction_message(current, text) do
    introduction =
      if Regex.match?(~r/\bconfirmation\b/i, text),
        do: "Let me correct the confirmation code.",
        else: "Here is your full confirmation code."

    tail =
      if current.reminder_status == "offered",
        do: " Would you like a text reminder 24 hours before your appointment?",
        else: " Your appointment remains booked."

    "#{introduction} Your appointment is already booked. Your full confirmation code is #{current.readout}.#{tail}"
  end

  defp announced?(text, already_read),
    do:
      (Regex.match?(~r/\bconfirmation(?:\s+(?:code|number))?\s*(?:is|[:,])?\s+\S/i, text) or
         (not already_read and Regex.match?(~r/\b(booked|confirmed)\b/i, text))) and
        Regex.match?(~r/[.!?]\s*$/, text)

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
