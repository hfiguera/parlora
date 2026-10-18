defmodule Parlora.TestSupport.OrderPolicy do
  @moduledoc false
  @behaviour Parlora.ContextPolicy
  alias Parlora.ContextDecision

  @impl true
  def interpret(snapshot, _trigger, options) do
    if observer = Keyword.get(options, :observer),
      do: send(observer, {:interpreting, snapshot.revision})

    text =
      snapshot.transcripts
      |> Enum.reverse()
      |> Enum.filter(&(&1.speaker == :user))
      |> Enum.map_join(& &1.delta)

    matches = Regex.scan(~r/order\s+(\d+)\b/i, text, capture: :all_but_first)
    order = matches |> Enum.reverse() |> List.first()
    {:ok, decide(snapshot, order)}
  end

  defp decide(_snapshot, nil), do: []

  defp decide(snapshot, [order]) do
    case Enum.find(snapshot.tasks, fn {_id, task} -> task.input.order != order end) do
      {id, task} ->
        [
          %ContextDecision{
            kind: :supersede_task,
            task_id: id,
            expected_task_revision: task.revision,
            input: %{order: order}
          }
        ]

      nil ->
        start(snapshot, order)
    end
  end

  defp pending?({_id, entry}), do: entry.status == :pending

  defp start(snapshot, order) do
    if map_size(snapshot.tasks) == 0 do
      case Enum.find(snapshot.pending_delegations, &pending?/1) do
        {id, _entry} ->
          [%ContextDecision{kind: :start_task, delegation_id: id, input: %{order: order}}]

        nil ->
          []
      end
    else
      []
    end
  end
end
