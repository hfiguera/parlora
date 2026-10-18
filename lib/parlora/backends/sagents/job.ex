defmodule Parlora.Backends.Sagents.Job do
  @moduledoc false
  alias Parlora.Backends.Result
  alias Parlora.Error
  # This framework is optional in packaged consumers; configuration checks it
  # before the first call. Keep its result types out of the public boundary.
  @compile {:no_warn_undefined, {Sagents.Agent, :execute, 3}}

  def name, do: "Sagents"

  def configuration(options) do
    runs = Keyword.get(options, :max_runs, 8)

    cond do
      not Code.ensure_loaded?(Sagents.Agent) ->
        Error.tuple(:unsupported, "Install optional sagents == 0.17.1 to use this backend")

      not is_function(Keyword.get(options, :agent), 1) or
        not is_function(Keyword.get(options, :result), 1) or
          not is_binary(Keyword.get(options, :completion_tool)) ->
        Error.tuple(
          :invalid_argument,
          "Sagents requires agent/result functions and a completion tool"
        )

      not is_integer(runs) or runs < 1 or runs > 100 ->
        Error.tuple(:invalid_argument, "Sagents max_runs must be between 1 and 100")

      true ->
        :ok
    end
  end

  def run(request, options, owner) do
    # Dependencies may log prompts or raw HTTP failures. Boundary events carry
    # sanitized reasons; model/tool internals remain inside this execution.
    Logger.put_process_level(self(), :none)
    {:ok, agent, initial} = Keyword.fetch!(options, :agent).(request)
    :ok = validate_agent(agent, initial)
    agent = %{agent | agent_id: request.id}
    send(owner, {:execution_started, request.id})

    execution =
      Sagents.Agent.execute(agent, initial,
        until_tool_success: Keyword.fetch!(options, :completion_tool),
        max_runs: Keyword.get(options, :max_runs, 8)
      )

    case execution do
      {:ok, _state, %{__struct__: LangChain.Message.ToolResult, is_error: false} = terminal} ->
        map_result(request, Keyword.fetch!(options, :result).(terminal))

      {:error, _error} ->
        {:uncertain, :framework_failure}

      _other ->
        {:uncertain, :structured_completion_missing}
    end
  rescue
    _exception -> {:uncertain, :execution_exception}
  catch
    _kind, _reason -> {:uncertain, :execution_exit}
  end

  defp validate_agent(
         %{
           __struct__: Sagents.Agent,
           middleware: [],
           fallback_models: [],
           before_fallback: nil,
           mode: mode,
           tools: tools
         },
         %{__struct__: Sagents.State}
       )
       when mode in [nil, Sagents.Modes.AgentExecution] do
    if Enum.all?(tools, &(Map.get(&1, :async) == false)),
      do: :ok,
      else: raise(ArgumentError, "Only synchronous tools are supported")
  end

  defp validate_agent(_agent, _state),
    do: raise(ArgumentError, "Use isolated execution without middleware or fallback models")

  defp map_result(request, %{status: _, facts: _} = mapped), do: Result.map(request, mapped)

  defp map_result(_request, _mapped), do: {:uncertain, :invalid_result}
end
