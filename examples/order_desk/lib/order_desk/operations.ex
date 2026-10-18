defmodule OrderDesk.Operations do
  @moduledoc "Application business operations shared by the backend integrations."
  def confirm(params) do
    case OrderDesk.Store.confirm(params.actor, params.proposal) do
      {:ok, result} -> {:ok, %{outcome: "applied", result: result}}
      {:error, reason} -> {:ok, %{outcome: Atom.to_string(reason)}}
    end
  catch
    :exit, _unavailable -> {:error, :outcome_unavailable}
  end

  def execute(params) do
    order = params.input.order
    delays = Application.get_env(:order_desk, :lookup_delays, %{})
    Process.sleep(Map.get(delays, order, 0))

    {delivery, data} =
      case OrderDesk.Store.order(order) do
        {:ok, record} ->
          operation = Map.get(params.input, :operation, "status")
          {describe(operation, record, params), read_data(operation, record)}

        {:error, :not_found} ->
          {"Order #{order} was not found for this demo customer. No action was taken.", %{}}
      end

    {:ok, %{status: :completed, last_answer: %{order: order, summary: delivery, data: data}}}
  end

  defp read_data("items", record), do: Map.take(record, [:items])
  defp read_data("status", record), do: Map.take(record, [:status, :tracking])
  defp read_data("instructions", record), do: Map.take(record, [:instructions, :version])
  defp read_data(_operation, _record), do: %{}

  defp describe("status", record, _params) do
    "Order #{record.id} is #{record.status}. Tracking reference: #{record.tracking}. " <>
      "Report only the stated status and timing; do not infer a delivery date or turn an estimate into a guarantee."
  end

  defp describe("instructions", record, _params),
    do:
      "Saved delivery instructions for order #{record.id}: #{if record.instructions == "", do: "none", else: record.instructions}. Record version #{record.version}. This is a database read; no changes were made."

  defp describe("items", record, _params),
    do:
      "Order #{record.id} contains " <>
        Enum.map_join(record.items, ", ", &"#{&1["quantity"]} #{&1["name"]}") <> "."

  defp describe("cancel", _record, _params),
    do:
      "I'll stop following that lookup. This does not cancel the purchase or change delivery instructions."

  defp describe("refuse", record, params) do
    case OrderDesk.Store.refuse(params.input.actor, record.id, params.input.proposal_id) do
      {:ok, :rejected} ->
        "The delivery draft for order #{record.id} was rejected. It cannot be confirmed. The saved delivery instructions were not changed."

      {:error, :already_applied} ->
        "That draft for order #{record.id} was already saved through browser confirmation. Refusing it now did not undo the saved change."

      {:error, _reason} ->
        "That draft is no longer available to reject. No delivery instructions were changed by this request."
    end
  end

  defp describe("delivery", record, params) do
    input = params.input

    case OrderDesk.Store.propose(input.actor, record.id, input.instructions, params.request_id) do
      {:ok, _proposal} ->
        "A draft for order #{record.id} says: #{input.instructions}. Nothing has been changed. Review the exact order and text on the page and press Confirm to save; spoken approval does not save it."

      {:error, _reason} ->
        "The delivery draft could not be created. No order changes were made. Use the order page."
    end
  end

  defp describe(_unsupported, _record, _params),
    do: "That operation is not supported. No changes were made."
end
