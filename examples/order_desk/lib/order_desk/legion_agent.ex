defmodule OrderDesk.LegionAgent do
  @moduledoc "Admitted operations and native evidence for isolated Legion Lua execution."

  def build(request, config) do
    operation = request.input[:operation] || "status"

    reads =
      if operation == "overview",
        do: [{"read_status", "status"}, {"read_items", "items"}],
        else: [{"lookup", operation}]

    operations =
      Map.new(reads, fn {name, operation} ->
        {name,
         fn ->
           {:ok, %{last_answer: answer}} =
             OrderDesk.Operations.execute(%{
               input: Map.put(request.input, :operation, operation),
               request_id: request.id,
               task_id: request.task_id,
               task_revision: request.task_revision
             })

           {:ok, answer}
         end}
      end)

    model =
      Map.get_lazy(config, :model_fixture, fn ->
        {:openai, config.model,
         reasoning_effort: :none,
         max_tokens: 1_000,
         receive_timeout: 8_000,
         total_timeout: :infinity,
         req_http_options: [retry: false],
         telemetry: [payloads: :none]}
      end)

    %{
      model: model,
      operations: operations,
      task: task(operation, request.input.order),
      verify: fn results, derived ->
        if request.input[:operation] == "overview" do
          match?(%{"item_count" => count} when is_integer(count), derived) and
            derived["item_count"] ==
              Enum.sum_by(results["read_items"].data.items, & &1["quantity"])
        else
          is_nil(derived)
        end
      end,
      result: fn results ->
        facts = %{order: request.input.order}

        facts =
          case results["read_items"] do
            %{data: %{items: items}} ->
              Map.put(facts, :item_count, Enum.sum_by(items, & &1["quantity"]))

            _other ->
              facts
          end

        %{
          status: :completed,
          facts: facts,
          summary: Enum.map_join(reads, " ", fn {name, _operation} -> results[name].summary end)
        }
      end
    }
  end

  defp task(operation, order) do
    "Execute the authorized #{operation} task for order #{order}. " <>
      "Tools return the native answer table directly; do not use table.pack or table.unpack. " <>
      instructions(operation)
  end

  defp instructions("overview") do
    "Call Tool.run(\"read_status\") and Tool.run(\"read_items\"). " <>
      "Sum the item quantities from read_items.data.items using Lua. " <>
      "Call Tool.complete({item_count = count}) with the computed count exactly once; then return."
  end

  defp instructions("delivery") do
    instructions("read") <>
      " Delivery creates a draft; only authenticated browser confirmation saves it."
  end

  defp instructions(_operation) do
    "Call Tool.run(\"lookup\") for the single admitted operation. " <>
      "Then call Tool.complete() with no arguments exactly once and return."
  end
end
