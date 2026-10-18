defmodule OrderDesk.Drafts do
  @moduledoc "Bind refusals to application-owned draft request IDs, never model-generated IDs."
  alias Parlora.ContextDecision, as: Decision

  def context(snapshot) do
    actor = Map.get(snapshot.application_context, :actor, "local")
    saved = OrderDesk.Store.dashboard(actor).proposals |> Map.new(&{&1.id, &1})

    snapshot.tasks
    |> Enum.filter(fn {_id, task} -> task.input.operation in ["delivery", "refuse"] end)
    |> Enum.sort_by(fn {_id, task} -> task.input.user_revision end, :desc)
    |> Enum.take(16)
    |> Enum.map(fn {_id, task} ->
      draft = saved[proposal_id(task)]

      %{
        order: task.input.order,
        status: if(draft, do: draft.status, else: "creation_requested"),
        instructions: task.input[:instructions]
      }
    end)
  end

  def refuse(snapshot, order, revision, pending, recovery, request_text) do
    target =
      snapshot.tasks
      |> Enum.filter(fn {_id, task} ->
        task.input.operation in ["delivery", "refuse"] and task.input.order == order
      end)
      |> Enum.max_by(fn {_id, task} -> task.input.user_revision end, fn -> nil end)

    case target do
      {id, %{input: %{operation: "refuse"}} = task} ->
        if pending do
          {delegation, _entry} = pending

          [
            %Decision{
              kind: :associate_delegation,
              task_id: id,
              expected_task_revision: task.revision,
              delegation_id: delegation
            }
          ]
        else
          []
        end

      {id, task} ->
        [
          %Decision{
            kind: :supersede_task,
            task_id: id,
            expected_task_revision: task.revision,
            input: %{
              order: order,
              operation: "refuse",
              actor: Map.get(snapshot.application_context, :actor, "local"),
              instructions: nil,
              user_revision: revision,
              proposal_id: proposal_id(task),
              request_text: request_text
            }
          }
        ]

      nil ->
        OrderDesk.Recovery.decide(
          recovery,
          "Which delivery draft would you like to reject? You can also use Reject draft on the page. No saved instructions were changed."
        )
    end
  end

  defp proposal_id(%{input: %{proposal_id: id}}), do: id
  defp proposal_id(task), do: List.first(Map.get(task, :request_ids, []))
end
