defmodule Parlora.TestSupport.ControlledPolicy do
  @moduledoc false
  @behaviour Parlora.ContextPolicy

  @impl true
  def interpret(snapshot, trigger, options) do
    send(Keyword.fetch!(options, :observer), {:policy, self(), snapshot, trigger})

    receive do
      {:decisions, decisions} -> {:ok, decisions}
      {:result, result} -> result
    after
      2_000 -> {:ok, []}
    end
  end
end
