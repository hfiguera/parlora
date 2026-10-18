defmodule OrderDesk.Backend do
  @moduledoc "Application selection and explicit framework configuration; Jido is the default."

  def selected do
    case Application.get_env(:order_desk, :backend, :jido) do
      :jido ->
        {Parlora.Backends.Jido,
         agent: OrderDesk.OrderAgent,
         agent_options: [jido: OrderDesk.Jido],
         result: &OrderDesk.map_result/1}

      :sagents ->
        config = Application.fetch_env!(:order_desk, :sagents)
        key = Map.fetch!(config, :api_key)
        if not is_binary(key) or key == "", do: raise("Sagents requires SAGENTS_API_KEY")

        if not Code.ensure_loaded?(Sagents.Agent),
          do: raise("Run PARLORA_BACKEND=sagents mix deps.get to install Sagents")

        {Parlora.Backends.Sagents,
         agent: fn request -> OrderDesk.SagentsAgent.build(request, config) end,
         completion_tool: "finish",
         max_runs: 6,
         result: &OrderDesk.SagentsAgent.result/1}

      :legion ->
        config = Application.fetch_env!(:order_desk, :legion)
        key = Map.fetch!(config, :api_key)
        if not is_binary(key) or key == "", do: raise("Legion requires LEGION_API_KEY")

        if not Code.ensure_loaded?(Legion),
          do: raise("Run PARLORA_BACKEND=legion mix deps.get to install Legion")

        {Parlora.Backends.Legion, execution: &OrderDesk.LegionAgent.build(&1, config)}
    end
  end
end
