defmodule BookingDesk.ReminderReadback do
  @moduledoc "Repair assistant phone readbacks from verified reminder state, without granting consent."
  alias BookingDesk.{ReadbackScope, Reminders}

  def turns(snapshot, current, opts \\ []) do
    ReadbackScope.turns(snapshot, Map.get(current, :request_id), :reminder_readback, opts)
  end

  def correction(
        snapshot,
        current,
        task,
        cursor,
        opts \\ []
      )

  def correction(
        snapshot,
        %{status: status, request_id: request} = current,
        %{
          status: task_status,
          request_ids: [request | _],
          input: %{cursor: cursor, operation: operation}
        } = task,
        cursor,
        opts
      )
      when status in ["verify_existing", "verify_new"] and
             task_status in [:submitted, :completed] and
             operation in ["reminder_opt_in", "reminder_number"] do
    case turns(snapshot, current, include_assistant_reply: true) |> List.last() do
      %{speaker: :assistant, first_cursor: first, text: text} when first > cursor ->
        previous = Map.get(scope(snapshot, current), :attempt, 0)

        if previous < 2 and wrong_number?(text, expected(current), opts) do
          attempt = previous + 1

          {question(current, attempt),
           ReadbackScope.input(snapshot, task, :reminder_readback, attempt)}
        end

      _ ->
        nil
    end
  end

  def correction(_, _, _, _, _), do: nil

  def verified?(snapshot, current, opts \\ [])

  def verified?(snapshot, %{status: status} = current, opts)
      when status in ["verify_existing", "verify_new"] do
    case turns(snapshot, current, include_assistant_reply: true) |> List.last() do
      %{speaker: :assistant, text: text} -> readback?(text, expected(current), opts)
      _ -> false
    end
  end

  def verified?(_, _, _), do: false

  # Only these complete, neutral sentences may precede the number question.
  # In particular, "one moment" is conversational filler, not a phone digit.
  defp question_text(text, opts) do
    if Keyword.get(opts, :reminder_recovery, false) do
      String.replace(
        text |> String.trim(),
        ~r/\A(?:(?:(?:great|okay|ok|sure|thanks)(?:,\s*one moment)?|one moment|let me correct that(?: number)?|your appointment remains booked)\.\s*)+/iu,
        ""
      )
    else
      text
    end
  end

  def readback?(text, expected, opts) do
    text = question_text(text, opts)

    Reminders.readback?(text, expected) and
      (not Keyword.get(opts, :reminder_recovery, false) or
         BookingDesk.Consent.unconditional?(String.replace(text, "?", "")))
  end

  def destination_question?(text, expected, opts),
    do:
      readback?(text, expected, opts) and
        Reminders.destination_question?(question_text(text, opts), expected)

  @doc false
  def echo(text, %{status: "verify_existing"} = current, question, opts)
      when is_binary(question) do
    if Keyword.get(opts, :reminder_recovery, false) and
         destination_question?(question, expected(current), opts) do
      {prefix, reply} = split_echo(String.trim(text))
      digits = Reminders.readback_digits(prefix)

      numeric? =
        Regex.match?(
          ~r/\A\s*(?:[0-9]|zero\b|oh\b|one\b|two\b|three\b|four\b|five\b|six\b|seven\b|eight\b|nine\b|[\s,.-])+\s*\z/iu,
          prefix
        )

      # An echo refers to the already verified suffix; it cannot supply or
      # complete a replacement number. Leading zeroes may be absent in captions.
      if numeric? and byte_size(digits) in 1..4 and
           String.ends_with?(expected(current), digits) do
        %{reply: reply, original: text}
      end
    end
  end

  def echo(_, _, _, _), do: nil

  defp split_echo(text) do
    case String.split(text, "?", parts: 2) do
      [prefix, reply] ->
        {prefix, reply}

      [text] ->
        # Live captions may punctuate the caller's question as a comma or omit
        # punctuation altogether. Only a digit-only prefix can be an echo.
        case Regex.run(~r/\A(.+?)(\b(?:yes|yep|yeah)\b.*)\z/iu, text, capture: :all_but_first) do
          [prefix, reply] -> {prefix, reply}
          _ -> {text, ""}
        end
    end
  end

  defp wrong_number?(text, expected, opts) do
    Regex.match?(~r/\?(?:\s*|\s+Your appointment remains booked\.\s*)$/i, text) and
      Regex.match?(~r/\b(cell|phone|number)\b|\b(send|text)\b.*\bto\b/i, text) and
      Reminders.readback_digits(text) != "" and not readback?(text, expected, opts)
  end

  defp expected(%{status: "verify_existing", destination: phone}),
    do: String.slice(phone, -4, 4)

  defp expected(%{destination: phone}), do: phone

  defp question(current, 1) do
    "Let me correct that number. Your appointment remains booked. Can we send the reminder to #{Reminders.spoken(expected(current))}?"
  end

  defp question(_, _),
    do:
      "I'm having trouble verifying the number readback. Your appointment remains booked. What phone number should we use? Please include all ten digits."

  defp scope(snapshot, current) do
    ReadbackScope.current(snapshot, Map.get(current, :request_id), :reminder_readback)
  end
end
