defmodule Parlora.Providers.Grok.Calls do
  @moduledoc false
  alias Parlora.{CommandLog, Error}
  alias Parlora.Providers.Grok.Protocol

  def new(limit), do: %{log: %CommandLog{limit: limit}, records: %{}}

  def admit(calls, %{"call_id" => id, "name" => name, "arguments" => encoded} = event)
      when is_binary(id) and id != "" and is_binary(encoded) and byte_size(encoded) <= 8_192 do
    with true <- name == Protocol.function(),
         {:ok, %{"request" => request} = args} <- Jason.decode(encoded),
         true <- map_size(args) == 1 and is_binary(request) and byte_size(request) in 1..4_096,
         {:new, log} <- CommandLog.admit(calls.log, id, {name, args}) do
      record = %{status: :pending, arguments: args, group: event["response_id"] || id}
      {:new, args, %{calls | log: log, records: Map.put(calls.records, id, record)}}
    else
      {:duplicate, _log} -> {:duplicate, calls}
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> Error.tuple(:invalid_argument, "Unknown function or malformed arguments")
    end
  end

  def admit(_calls, _event), do: Error.tuple(:invalid_argument, "Malformed function call")

  def context(calls, nil, content), do: {:ok, Protocol.text(content), calls}

  def context(calls, id, content) do
    case calls.records[id] do
      %{status: :pending} -> complete(calls, id, %{result: content})
      %{status: :completed} -> {:ok, Protocol.text(content), calls}
      _unknown -> Error.tuple(:invalid_argument, "Unknown or superseded delegation")
    end
  end

  def complete(calls, id, outcome) do
    case calls.records[id] do
      %{status: :pending} = record ->
        status = if outcome[:status] == :superseded, do: :superseded, else: :completed
        {:ok, Protocol.result(id, outcome), put_in(calls.records[id], %{record | status: status})}

      _terminal ->
        Error.tuple(:invalid_argument, "Delegation is no longer pending")
    end
  end

  def group_pending?(_calls, nil), do: false

  def group_pending?(calls, id) do
    group = calls.records[id].group

    Enum.any?(calls.records, fn {_id, record} ->
      record.group == group and record.status == :pending
    end)
  end
end
