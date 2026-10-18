defmodule Parlora.Backends.Result do
  @moduledoc false
  alias Parlora.BackendResult

  def map(request, mapped, statuses \\ [:completed, :failed])

  def map(request, %{status: status, facts: facts} = mapped, statuses)
      when is_map(facts) do
    summary = Map.get(mapped, :summary)

    if status in statuses and (is_nil(summary) or is_binary(summary)) and
         :erlang.external_size(mapped) <= 65_536 do
      {:ok,
       %BackendResult{
         request_id: request.id,
         task_id: request.task_id,
         task_revision: request.task_revision,
         provider_generation: request.provider_generation,
         status: status,
         facts: facts,
         summary: summary,
         error: Map.get(mapped, :error)
       }}
    else
      {:uncertain, :invalid_result}
    end
  end

  def map(_request, _mapped, _statuses), do: {:uncertain, :invalid_result}
end
