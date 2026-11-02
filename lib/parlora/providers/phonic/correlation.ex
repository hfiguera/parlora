defmodule Parlora.Providers.Phonic.Correlation do
  @moduledoc false
  alias Parlora.Error
  alias Parlora.Providers.Phonic.{Calls, Protocol}

  def context(calls, update, call, scope) do
    with {:ok, prepared, scope} <- prepare(Protocol.text(update.content), update, call, scope),
         {:ok, command, calls} <-
           Calls.context(
             calls,
             Map.get(prepared, :tool_call_id, update.delegation_id),
             update.content
           ) do
      command = if prepared.type == "tool_call_output", do: prepared, else: command

      calls =
        if prepared.type == "tool_call_output",
          do: Calls.stage_output(calls, prepared.tool_call_id, prepared.output),
          else: calls

      {:ok, command, calls, scope}
    end
  end

  def validate(
        %{task_id: task, task_revision: revision, provider_generation: generation},
        generation
      )
      when is_binary(task) and byte_size(task) in 1..256 and is_integer(revision) and revision > 0,
      do: :ok

  def validate(_, _), do: invalid("Invalid native task correlation")

  def prepare(command, %{kind: :speakable} = update, call, scope) when is_binary(call) do
    cond do
      stale?(update, scope) ->
        invalid("Obsolete native task revision")

      update.delegation_id == call and conflicting_task?(update, scope) ->
        invalid("Native call belongs to a different task")

      update.delegation_id == call or same_task?(update, scope) ->
        correlate(update, call, scope)

      true ->
        {:ok, command, scope}
    end
  end

  def prepare(command, _update, _call, scope), do: {:ok, command, scope}

  def bind(entries, call, scope) do
    scope = Enum.reduce(entries, scope, fn entry, acc -> advance(acc, entry.update) end)
    {obsolete, keep} = Enum.split_with(entries, &stale?(&1.update, scope))

    result =
      Enum.reduce_while(keep, {:ok, []}, fn entry, {:ok, acc} ->
        case prepare(entry.command, entry.update, call, scope) do
          {:ok, command, _scope} -> {:cont, {:ok, [%{entry | command: command} | acc]}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed), scope, obsolete}
      error -> error
    end
  end

  def hold?(%{status: :associated, task_status: :submitted}, _queued?), do: true

  def hold?(%{status: :associated, task_status: :completed, result_delivery: stage}, queued?),
    do: stage in [:pending, :held] or (stage == :awaiting_provider and queued?)

  def hold?(_, _), do: false

  defp correlate(update, call, scope) do
    output = %{result: update.content}

    with :ok <- Protocol.valid_output?(output) do
      {:ok, Protocol.result(call, output), advance(scope, update)}
    end
  end

  defp same_task?(%{task_id: task, task_revision: revision}, %{task_id: task})
       when is_binary(task) and is_integer(revision) and revision > 0, do: true

  defp same_task?(_, _), do: false

  defp conflicting_task?(%{task_id: task}, %{task_id: expected}) when is_binary(task),
    do: task != expected

  defp conflicting_task?(_, _), do: false

  defp stale?(%{task_revision: revision} = update, %{task_revision: current} = scope),
    do: same_task?(update, scope) and revision < current

  defp stale?(_, _), do: false

  defp advance(nil, %{task_id: task, task_revision: revision, provider_generation: generation})
       when is_binary(task) and is_integer(revision) and revision > 0,
       do: %{task_id: task, task_revision: revision, provider_generation: generation}

  defp advance(%{task_revision: current} = scope, %{task_revision: revision} = update) do
    if same_task?(update, scope) and revision > current,
      do: %{scope | task_revision: revision},
      else: scope
  end

  defp advance(scope, _), do: scope

  defp invalid(message), do: Error.tuple(:invalid_argument, message)
end
