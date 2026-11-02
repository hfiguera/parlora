defmodule BookingDesk.ReadbackScope do
  @moduledoc "Caption boundaries for corrections tied to one receipt, task revision and provider generation."

  def turns(snapshot, request, kind, opts \\ []) do
    boundary = current(snapshot, request, kind)[:after_cursor]

    snapshot.transcripts
    |> Enum.reject(fn part ->
      part.speaker == :assistant and
        ((boundary != nil and part.arrival_order <= boundary) or
           Map.get(part, :provider_generation, snapshot.provider_generation) !=
             snapshot.provider_generation)
    end)
    |> BookingDesk.Dialogue.build(Keyword.put(opts, :with_cursor, true))
  end

  def input(snapshot, task, kind, attempt) do
    %{
      kind => %{
        request_id: hd(task.request_ids),
        provider_generation: snapshot.provider_generation,
        task_revision: task.revision,
        after_cursor: snapshot.transcripts |> Enum.map(& &1.arrival_order) |> Enum.max(),
        attempt: attempt
      }
    }
  end

  def current(snapshot, request, kind) do
    snapshot
    |> Map.get(:tasks, %{})
    |> Map.values()
    |> Enum.find_value(%{}, fn task ->
      current_task(task, request, kind, snapshot.provider_generation)
    end)
  end

  defp current_task(
         %{revision: revision, request_ids: [request | _], clarification: %{input: input}},
         request,
         kind,
         generation
       ) do
    case input[kind] do
      %{request_id: ^request, provider_generation: ^generation, task_revision: ^revision} = scope ->
        scope

      _ ->
        nil
    end
  end

  defp current_task(_, _, _, _), do: nil
end
