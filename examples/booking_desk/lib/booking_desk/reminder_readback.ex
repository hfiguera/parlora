defmodule BookingDesk.ReminderReadback do
  @moduledoc "Repair assistant phone readbacks from verified reminder state, without granting consent."
  alias BookingDesk.{ReadbackScope, Reminders}

  def turns(snapshot, current, opts \\ []) do
    ReadbackScope.turns(snapshot, Map.get(current, :request_id), :reminder_readback, opts)
  end

  def correction(
        snapshot,
        %{status: status, request_id: request} = current,
        %{
          status: task_status,
          request_ids: [request | _],
          input: %{cursor: cursor, operation: operation}
        } = task,
        cursor
      )
      when status in ["verify_existing", "verify_new"] and
             task_status in [:submitted, :completed] and
             operation in ["reminder_opt_in", "reminder_number"] do
    case turns(snapshot, current, include_assistant_reply: true) |> List.last() do
      %{speaker: :assistant, first_cursor: first, text: text} when first > cursor ->
        previous = Map.get(scope(snapshot, current), :attempt, 0)

        if previous < 2 and wrong_number?(text, expected(current)) do
          attempt = previous + 1

          {question(current, attempt),
           ReadbackScope.input(snapshot, task, :reminder_readback, attempt)}
        end

      _ ->
        nil
    end
  end

  def correction(_, _, _, _), do: nil

  def verified?(snapshot, %{status: status} = current)
      when status in ["verify_existing", "verify_new"] do
    case turns(snapshot, current, include_assistant_reply: true) |> List.last() do
      %{speaker: :assistant, text: text} -> Reminders.readback?(text, expected(current))
      _ -> false
    end
  end

  def verified?(_, _), do: false

  defp wrong_number?(text, expected) do
    Regex.match?(~r/\?(?:\s*|\s+Your appointment remains booked\.\s*)$/i, text) and
      Regex.match?(~r/\b(cell|phone|number)\b|\b(send|text)\b.*\bto\b/i, text) and
      Reminders.readback_digits(text) != "" and not Reminders.readback?(text, expected)
  end

  defp expected(%{status: "verify_existing", destination: phone}),
    do: String.slice(phone, -4, 4)

  defp expected(%{destination: phone}), do: phone

  defp question(current, 1) do
    "Let me correct that number. Your appointment remains booked. Can we send the reminder to #{Reminders.spoken(expected(current))}?"
  end

  defp question(_, _),
    do:
      "I'm having trouble verifying the number readback. Your appointment remains booked. What cell number should we use? Please include all ten digits."

  defp scope(snapshot, current) do
    ReadbackScope.current(snapshot, Map.get(current, :request_id), :reminder_readback)
  end
end
