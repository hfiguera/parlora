defmodule BookingDesk.SearchClarification do
  @moduledoc "A scoped yes/no continuation for a read-only replacement search."
  alias BookingDesk.{Dialogue, Reply, Store}

  def offer(snapshot, %{input: %{operation: "availability"}} = task, request, cursor) do
    date = request["date"]
    clinician = request["clinician"]

    if date in Store.dates() and clinician in ~w(lee patel any) and
         (date != task.input.date or clinician != task.input.clinician) do
      day = date |> Date.from_iso8601!() |> Calendar.strftime("%B %-d, %Y")
      doctor = Map.get(Store.clinicians(), clinician, "any available doctor")

      preferred =
        case request["time"] do
          "10:15" -> "I've kept your preferred time of 10:15 AM. "
          "14:00" -> "I've kept your preferred time of 2:00 PM. "
          _ -> ""
        end

      message =
        preferred <>
          "Should I replace the current search with availability for #{day} with #{doctor}? Nothing has been booked."

      action = %{
        kind: :replace_search,
        task_id: task.id,
        task_revision: task.revision,
        generation: snapshot.provider_generation,
        cursor: cursor,
        date: date,
        clinician: clinician,
        question: message
      }

      {message, action}
    end
  end

  def offer(_, _, _, _), do: nil

  def reply(snapshot, task, lookup, preferences, cursor, text, opts \\ []) do
    with %{input: %{operation: "availability"}, clarification: %{input: input}} <- task,
         %{lookup_request: ^lookup, search_clarification: action} when is_binary(lookup) <- input,
         true <- current?(snapshot, task, action, preferences, cursor),
         {:ok, spoken} <- asked(snapshot, task, action) do
      case Reply.answer(
             action.question,
             spoken,
             text,
             Map.take(action, [:task_id, :task_revision, :generation, :cursor]),
             opts
           ) do
        {:ok, :accept} ->
          {:ok,
           %{"intent" => "replace_search", "date" => action.date, "clinician" => action.clinician}}

        {:ok, :decline} ->
          {:decline, action}

        {:ok, :repeat} ->
          {:repeat, action}

        _ ->
          :unresolved
      end
    else
      _ -> :unresolved
    end
  end

  defp current?(snapshot, task, %{kind: :replace_search} = action, preferences, cursor) do
    action.task_id == task.id and action.task_revision == task.revision and
      action.generation == snapshot.provider_generation and cursor > action.cursor and
      action.date in Store.dates() and action.clinician in ~w(lee patel any) and
      preferences["date"] == action.date and preferences["clinician"] == action.clinician
  end

  defp current?(_, _, _, _, _), do: false

  defp asked(snapshot, task, action) do
    turns =
      Dialogue.build(snapshot.transcripts, after_cursor: task.input.cursor, with_cursor: true)

    case Enum.reverse(turns) do
      [
        %{speaker: :user, first_cursor: answered},
        %{speaker: :assistant, text: question, first_cursor: asked} | _
      ]
      when asked > action.cursor and answered > asked ->
        {:ok, question}

      _ ->
        :unresolved
    end
  end
end
