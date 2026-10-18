defmodule Parlora.Backends.Legion.Job do
  @moduledoc false
  alias Parlora.Backends.Legion.{Agent, Collector}
  alias Parlora.Backends.Result
  alias Parlora.Error

  @compile {:no_warn_undefined,
            [
              {Legion, :start_link, 2},
              {Legion, :call, 3},
              {Vault, :unsafe_put, 2},
              {Vault, :get, 1}
            ]}

  @defaults [
    max_iterations: 6,
    max_retries: 1,
    max_tool_calls: 16,
    sandbox_timeout: 5_000,
    sandbox_max_heap: 32_000_000,
    sandbox_max_reductions: 2_000_000
  ]

  def name, do: "Legion"

  def configuration(options) do
    cond do
      not Code.ensure_loaded?(Legion) ->
        Error.tuple(:unsupported, "Install optional legion == 0.6.0 to use this backend")

      not is_function(options[:execution], 1) ->
        Error.tuple(:invalid_argument, "Legion requires an execution factory")

      not valid_limits?(Keyword.merge(@defaults, options)) ->
        Error.tuple(:invalid_argument, "Legion requires finite execution and resource limits")

      Application.get_env(:legion, :store) != nil or
          Application.get_env(:legion, :recovery) != nil ->
        Error.tuple(:unsupported, "Legion persistence and recovery are unsupported")

      true ->
        :ok
    end
  end

  def run(request, options, owner) do
    Logger.put_process_level(self(), :none)
    if Vault.get(:store) != nil, do: raise(ArgumentError, "Inherited persistence is unsupported")
    execution = options[:execution].(request)
    :ok = validate_execution(execution)
    limits = Keyword.merge(@defaults, options)
    {:ok, collector} = Collector.start_link(execution, limits[:max_tool_calls])
    Vault.unsafe_put(:store, nil)
    Vault.unsafe_put(:parlora_legion_collector, collector)

    try do
      execute(request, execution, limits, collector, owner)
    after
      stop(collector)
    end
  rescue
    _exception -> {:uncertain, :execution_exception}
  catch
    _kind, _reason -> {:uncertain, :execution_exit}
  end

  defp execute(request, execution, limits, collector, owner) do
    agent_options =
      Keyword.take(limits, Keyword.keys(@defaults) -- [:max_tool_calls]) ++
        [
          model: execution.model,
          sandbox: Legion.Sandbox.Lua,
          binding_scope: :turn,
          max_message_length: 8_192,
          start_mode: :normal,
          eval_guard: nil,
          rate_limit: [rules: []]
        ]

    {:ok, agent} = Legion.start_link(Agent, agent_options)

    try do
      send(owner, {:execution_started, request.id})
      outcome = Legion.call(agent, execution.task, :infinity)

      case outcome do
        {:ok, _model_value} -> map_result(request, Collector.result(collector))
        _other -> {:uncertain, :framework_failure}
      end
    after
      stop(agent)
    end
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(ref, [:flush])
    end
  end

  defp valid_limits?(options) do
    Enum.all?(@defaults, fn {key, _default} ->
      value = options[key]

      is_integer(value) and value >= if(key == :max_retries, do: 0, else: 1) and
        value <= maximum(key)
    end)
  end

  defp maximum(:max_retries), do: 3
  defp maximum(:max_iterations), do: 20
  defp maximum(:max_tool_calls), do: 128
  defp maximum(:sandbox_timeout), do: 30_000
  defp maximum(:sandbox_max_heap), do: 128_000_000
  defp maximum(:sandbox_max_reductions), do: 10_000_000

  defp validate_execution(%{model: _model, task: task, operations: operations, result: mapper})
       when is_binary(task) and byte_size(task) <= 8_192 and is_map(operations) and
              map_size(operations) > 0 and map_size(operations) <= 16 and is_function(mapper, 1) do
    if Enum.all?(operations, fn {name, fun} ->
         is_binary(name) and byte_size(name) in 1..64 and is_function(fun, 0)
       end), do: :ok, else: raise(ArgumentError, "Invalid operations")
  end

  defp validate_execution(_execution), do: raise(ArgumentError, "Invalid Legion execution")

  defp map_result(request, %{status: _, facts: _} = mapped), do: Result.map(request, mapped)

  defp map_result(_request, _mapped), do: {:uncertain, :structured_completion_missing}
end
