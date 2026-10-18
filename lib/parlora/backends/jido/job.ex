defmodule Parlora.Backends.Jido.Job do
  @moduledoc false
  alias Jido.{AgentServer, Signal}
  alias Parlora.Backends.Result

  @compile {:no_warn_undefined,
            [
              {Jido.AgentServer, :start_link, 1},
              {Jido.AgentServer, :cast, 2},
              {Jido.AgentServer, :await_completion, 2},
              {Jido.Signal, :new!, 3}
            ]}

  def run(request, options, owner) do
    agent = Keyword.fetch!(options, :agent)

    server_options =
      Keyword.get(options, :agent_options, []) |> Keyword.merge(agent: agent, id: request.id)

    {:ok, pid} = AgentServer.start_link(server_options)
    send(owner, {:jido_started, request.id, pid})

    try do
      signal =
        case Keyword.get(options, :signal) do
          nil ->
            Signal.new!(
              "parlora.request",
              %{
                input: request.input,
                request_id: request.id,
                task_id: request.task_id,
                task_revision: request.task_revision
              },
              %{source: "/parlora"}
            )

          mapper ->
            mapper.(request)
        end

      :ok = AgentServer.cast(pid, signal)
      await_options = Keyword.get(options, :await_options, []) |> Keyword.put(:timeout, :infinity)
      {:ok, terminal} = AgentServer.await_completion(pid, await_options)
      map_result(request, terminal, Keyword.fetch!(options, :result))
    after
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end
  end

  defp map_result(request, terminal, mapper) do
    mapped = mapper.(terminal)
    mapped = if is_map(mapped), do: Map.put_new(mapped, :facts, %{}), else: mapped

    # Jido may explicitly confirm cancellation. The other bounded runners keep
    # their completed/failed-only contract; stopping local work is not proof.
    case Result.map(request, mapped, [:completed, :failed, :cancelled]) do
      {:ok, result} -> result
      uncertain -> uncertain
    end
  rescue
    _exception -> {:uncertain, :invalid_result}
  catch
    _kind, _reason -> {:uncertain, :invalid_result}
  end
end
