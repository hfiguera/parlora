defmodule Parlora.Providers.Gemini.Calls do
  @moduledoc false
  alias Parlora.{CommandLog, Error}
  alias Parlora.Providers.Gemini.Protocol

  def new(limit), do: %{records: %{}, commands: %CommandLog{limit: limit}}

  def admit(calls, %{"id" => id, "name" => name, "args" => args} = call)
      when is_binary(id) and id != "" and is_map(args) do
    if name == Protocol.function() and valid_args?(args) do
      case CommandLog.admit(calls.commands, id, call) do
        {:new, commands} ->
          record = %{status: :pending, name: name, args: args}
          {:new, %{calls | commands: commands, records: Map.put(calls.records, id, record)}}

        {:duplicate, _commands} ->
          {:duplicate, calls}

        error ->
          error
      end
    else
      Error.tuple(:invalid_argument, "Unknown function or malformed arguments")
    end
  end

  def admit(_calls, _call), do: Error.tuple(:invalid_argument, "Malformed function call")

  def cancel(calls, id) do
    case calls.records[id] do
      %{status: :pending} = record ->
        {:cancelled, put_in(calls.records[id], %{record | status: :cancelled})}

      _unknown_or_terminal ->
        {:unchanged, calls}
    end
  end

  def context(calls, nil, content), do: {:ok, Protocol.text(content), calls}

  def context(calls, id, content) do
    case calls.records[id] do
      %{status: :pending} ->
        complete(calls, id, %{result: content})

      %{status: :completed} ->
        # A clarification already closed the function call. A later application
        # result is new context, never a second response to a finished call.
        {:ok, Protocol.text(content), calls}

      %{status: :cancelled} ->
        Error.tuple(:invalid_argument, "Function call was cancelled")

      nil ->
        Error.tuple(:invalid_argument, "Unknown function call")
    end
  end

  def complete(calls, id, response) do
    case calls.records[id] do
      %{status: :pending} = record ->
        {:ok, Protocol.tool_result(id, response, scheduling(response)),
         put_in(calls.records[id], %{record | status: :completed})}

      _terminal_or_unknown ->
        Error.tuple(:invalid_argument, "Function call is no longer pending")
    end
  end

  def pending?(calls), do: Enum.any?(calls.records, fn {_id, r} -> r.status == :pending end)

  # An associated call must terminate, but a result already submitted through
  # another command must not schedule another spoken answer. Submission is not
  # playback evidence. Rejected/not-delivered results retain normal scheduling.
  defp scheduling(%{status: :associated, result_delivery: delivery})
       when delivery in [
              nil,
              :pending,
              :awaiting_provider,
              :accepted,
              :unconfirmed,
              :unknown,
              :done
            ],
       do: "SILENT"

  defp scheduling(_response), do: "WHEN_IDLE"

  defp valid_args?(%{"request" => request} = args),
    do: map_size(args) == 1 and is_binary(request) and byte_size(request) in 1..4_096

  defp valid_args?(_args), do: false
end
