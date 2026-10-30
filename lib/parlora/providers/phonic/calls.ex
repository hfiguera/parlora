defmodule Parlora.Providers.Phonic.Calls do
  @moduledoc false
  alias Parlora.{CommandLog, Error}
  alias Parlora.Providers.Phonic.Protocol

  def new(limit), do: %{log: %CommandLog{limit: limit}, records: %{}}

  def admit(calls, %{"tool_call_id" => id, "tool_name" => name, "parameters" => args})
      when is_binary(id) and byte_size(id) in 1..256 and is_map(args) do
    with true <- name == Protocol.function(),
         %{"request" => request} when map_size(args) == 1 <- args,
         true <- is_binary(request) and byte_size(request) in 1..4_096,
         {:new, log} <- CommandLog.admit(calls.log, id, {name, args}) do
      record = %{status: :pending, arguments: args, outcome: nil}
      {:new, args, %{calls | log: log, records: Map.put(calls.records, id, record)}}
    else
      {:duplicate, _log} -> {:duplicate, calls}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> Error.tuple(:invalid_argument, "Unknown function or malformed arguments")
    end
  end

  def admit(_calls, _event), do: Error.tuple(:invalid_argument, "Malformed Phonic tool call")

  def context(calls, nil, content), do: {:ok, Protocol.text(content), calls}

  def context(calls, id, content) do
    case calls.records[id] do
      %{status: :pending} ->
        complete(calls, id, %{result: content})

      %{status: status} when status in [:completed, :expired] ->
        {:ok, Protocol.text(content), calls}

      _unknown_or_cancelled ->
        Error.tuple(:invalid_argument, "Unknown, cancelled or superseded delegation")
    end
  end

  def complete(calls, id, outcome) do
    case calls.records[id] do
      %{status: :pending} = record ->
        complete_pending(calls, id, record, outcome)

      %{outcome: ^outcome} when not is_nil(outcome) ->
        {:duplicate, calls}

      %{status: :expired} ->
        {:expired, calls}

      _terminal ->
        Error.tuple(:invalid_argument, "Delegation is no longer pending")
    end
  end

  defp complete_pending(calls, id, record, outcome) do
    with :ok <- Protocol.valid_output?(outcome) do
      status = if outcome[:status] == :superseded, do: :superseded, else: :completed
      record = %{record | status: status, outcome: outcome}
      {:ok, Protocol.result(id, outcome), put_in(calls.records[id], record)}
    end
  end

  def cancel(calls, id), do: transition(calls, id, :cancelled)
  def expire(calls, id), do: transition(calls, id, :expired)

  defp transition(calls, id, status) do
    case calls.records[id] do
      %{status: current} = record when current in [:pending, :completed] ->
        {:changed, put_in(calls.records[id], %{record | status: status})}

      _unknown_or_terminal ->
        {:unchanged, calls}
    end
  end
end
