defmodule Parlora.Backends.Legion.Tool do
  @moduledoc false
  alias Parlora.Backends.Legion.Collector
  @compile {:no_warn_undefined, {Vault, :get, 1}}
  if Code.ensure_loaded?(Legion.Tool), do: @behaviour(Legion.Tool)

  def description do
    names = Collector.names(collector()) |> Enum.map_join(", ", &inspect/1)

    "Tool.run(name) executes one admitted operation; allowed names: #{names}. " <>
      "Returns the native answer table directly; errors raise. Do not wrap the return in table.pack or table.unpack. " <>
      "Tool.complete() requires all reads and records their native results. " <>
      "After complete, stop. No tool saves a delivery draft without browser confirmation."
  end

  def extra_allowed_modules, do: []
  def summary, do: "Execute admitted operations and record their native completion."
  def mcp?, do: false
  def run(name), do: Collector.operation(collector(), name) |> value()
  def complete(derived \\ nil), do: Collector.complete(collector(), derived) |> value()

  defp value({:ok, value}), do: value
  defp value({:error, message}), do: raise(ArgumentError, message)

  defp collector, do: Vault.get(__MODULE__)[:collector]
end
