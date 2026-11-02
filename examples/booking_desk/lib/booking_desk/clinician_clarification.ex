defmodule BookingDesk.ClinicianClarification do
  @moduledoc "A scoped read-only doctor clarification for the scripted caller."

  def tag(input, snapshot, %{id: id, revision: revision}, missing) do
    if "clinician" in missing do
      Map.put(input, :clinician_clarification, %{
        task_id: id,
        task_revision: revision,
        provider_generation: snapshot.provider_generation
      })
    else
      input
    end
  end

  def tag(input, _, _, _), do: input

  def pending(snapshot, lookup, %{confirmed: true, insurance_request: request}, date) do
    Enum.find_value(snapshot.tasks, fn {_, task} ->
      current_question(task, lookup, request, date, snapshot.provider_generation)
    end)
  end

  def pending(_, _, _, _), do: nil

  defp current_question(
         %{
           id: id,
           revision: revision,
           status: :completed,
           input: %{operation: "insurance", lookup_request: lookup},
           request_ids: [request | _],
           clarification: %{command_id: command, input: input}
         },
         lookup,
         request,
         date,
         generation
       )
       when is_binary(command) do
    case input do
      %{
        lookup_request: ^lookup,
        missing_fields: ["clinician"],
        booking_request: %{"date" => ^date},
        clinician_clarification: %{
          task_id: ^id,
          task_revision: ^revision,
          provider_generation: ^generation
        }
      } ->
        %{
          question_id: command,
          task_id: id,
          task_revision: revision,
          lookup_request: lookup,
          provider_generation: generation
        }

      _ ->
        nil
    end
  end

  defp current_question(_, _, _, _, _), do: nil
end
