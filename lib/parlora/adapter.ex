defmodule Parlora.Adapter do
  @moduledoc false
  alias Parlora.Error

  # A closure keeps startup options out of supervisor crash-report MFA arguments.
  # Adapter format_status/1 still owns redaction of its running state.
  def start_link(starter) when is_function(starter, 0), do: starter.()

  @spec call(pid(), term(), pos_integer()) :: term()
  def call(pid, message, timeout \\ 1_000) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _call} ->
      Error.tuple(:timeout, "Admission is uncertain; reconcile the command ID")

    :exit, {:noproc, _call} ->
      Error.tuple(:closed, "Adapter is closed")

    :exit, {:normal, _call} ->
      Error.tuple(:closed, "Adapter is closed")

    :exit, {:shutdown, _call} ->
      Error.tuple(:closed, "Adapter is shutting down")

    :exit, {_reason, {GenServer, :call, _arguments}} ->
      Error.tuple(:adapter_failed, "Adapter exited during the call; admission is uncertain")
  end
end
