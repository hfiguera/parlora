defmodule BookingDesk.ReminderReadback do
  @moduledoc "Repair assistant phone readbacks from verified reminder state, without granting consent."
  alias BookingDesk.{Dialogue, Reminders}

  def turns(snapshot, current, opts \\ []) do
    boundary = scope(snapshot, current)[:after_cursor]

    snapshot.transcripts
    |> Enum.reject(fn part ->
      part.speaker == :assistant and
        ((boundary != nil and part.arrival_order <= boundary) or
           Map.get(part, :provider_generation, snapshot.provider_generation) !=
             snapshot.provider_generation)
    end)
    |> Dialogue.build(Keyword.put(opts, :with_cursor, true))
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
           %{
             reminder_readback: %{
               request_id: current.request_id,
               provider_generation: snapshot.provider_generation,
               task_revision: task.revision,
               after_cursor: snapshot.transcripts |> Enum.map(& &1.arrival_order) |> Enum.max(),
               attempt: attempt
             }
           }}
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
    String.contains?(text, "?") and
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
    snapshot
    |> Map.get(:tasks, %{})
    |> Map.values()
    |> Enum.find_value(%{}, fn task ->
      current_scope(task, current, snapshot.provider_generation)
    end)
  end

  defp current_scope(
         %{revision: revision, request_ids: [request | _], clarification: %{input: input}},
         %{request_id: request},
         generation
       ) do
    case input do
      %{
        reminder_readback:
          %{
            request_id: ^request,
            provider_generation: ^generation,
            task_revision: ^revision
          } = scope
      } ->
        scope

      _ ->
        nil
    end
  end

  defp current_scope(_, _, _), do: nil
end
