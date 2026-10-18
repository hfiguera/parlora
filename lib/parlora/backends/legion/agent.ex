defmodule Parlora.Backends.Legion.Agent do
  @moduledoc false
  alias Parlora.Backends.Legion.Tool
  @compile {:no_warn_undefined, {Vault, :get, 1}}

  def tools, do: [Parlora.Backends.Legion.Tool]
  def config, do: %{}
  def output_schema, do: %{"type" => "string"}
  def action_types, do: ~w(eval_and_continue eval_and_complete)
  def moduledoc, do: "Execute the admitted operations using Lua, then call Tool.complete()."

  # Legion's general prompt allows code-result completion. This integration
  # requires native completion evidence even when the generated code returns.
  def system_prompt do
    "Execute the admitted task in a Lua 5.3 sandbox. " <>
      "Use eval_and_complete to perform all required reads and calculations in one execution when possible. " <>
      "Use eval_and_continue only when another model step is necessary. " <>
      "Never execute readiness, preflight or demonstration code. " <>
      "Returning Tool.run output alone does not complete the business task. " <>
      "Your code MUST call Tool.complete after all required operations, before returning. " <>
      "Pass a derived value only when the task explicitly requires it. " <>
      "Stop after successful completion. The JSON result field must be an empty string. " <>
      "Tool.run returns the native answer table directly, never multiple values or a status tuple. " <>
      "Use only the operation names admitted by the task; do not substitute other names. " <>
      "Lua has ipairs, pairs, table.unpack and standard string/math functions. " <>
      "No print, io, filesystem, os, require, load or host module access. " <>
      Tool.description()
  end

  def tool_config(_tool) do
    Logger.put_process_level(self(), :none)
    [collector: Vault.get(:parlora_legion_collector)]
  end
end
