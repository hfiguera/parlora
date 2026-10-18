defmodule Parlora.CommandLog do
  @moduledoc false
  alias Parlora.Error

  @type t :: %__MODULE__{entries: map(), limit: pos_integer()}
  defstruct entries: %{}, outcomes: %{}, limit: 4_096

  @spec admit(t(), String.t(), term()) :: {:new | :duplicate, t()} | {:error, Error.t()}
  def admit(log, id, command) when is_binary(id) and byte_size(id) > 0 do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(command))

    case Map.fetch(log.entries, id) do
      {:ok, ^digest} -> {:duplicate, log}
      {:ok, _other} -> Error.tuple(:invalid_argument, "Conflicting command ID")
      :error -> insert(log, id, digest)
    end
  end

  def admit(_log, _id, _command),
    do: Error.tuple(:invalid_argument, "Command ID must be a nonempty string")

  def run(state, id, command, handler) do
    case admit(state.commands, id, command) do
      {:duplicate, log} -> {:reply, reply(log, id), state}
      {:new, log} -> complete(handler.(state, id, command), log, id)
      error -> {:reply, error, state}
    end
  end

  def reply(log, id), do: Map.get(log.outcomes, id, :ok)

  def complete({:reply, reply, state}, log, id) do
    commands = %{log | outcomes: Map.put(log.outcomes, id, reply)}
    {:reply, reply, %{state | commands: commands}}
  end

  defp insert(log, id, digest) when map_size(log.entries) < log.limit,
    do: {:new, %{log | entries: Map.put(log.entries, id, digest)}}

  defp insert(_log, _id, _digest),
    do: Error.tuple(:backpressure, "Command record capacity exhausted")
end
