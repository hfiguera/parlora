defmodule Parlora.Backends.Legion.Collector do
  @moduledoc false
  use GenServer

  def start_link(execution, budget), do: GenServer.start_link(__MODULE__, {execution, budget})
  def operation(pid, name), do: GenServer.call(pid, {:operation, name}, :infinity)
  def complete(pid, derived), do: GenServer.call(pid, {:complete, derived}, :infinity)
  def result(pid), do: GenServer.call(pid, :result)
  def names(pid), do: GenServer.call(pid, :names)

  @impl true
  def init({execution, budget}) do
    Logger.put_process_level(self(), :none)
    {:ok, %{execution: execution, budget: budget, results: %{}, terminal: nil, failed: false}}
  end

  @impl true
  def handle_call(:names, _from, state),
    do: {:reply, Map.keys(state.execution.operations) |> Enum.sort(), state}

  def handle_call(:result, _from, state),
    do: {:reply, if(state.failed, do: nil, else: state.terminal), state}

  def handle_call(command, _from, state) do
    cond do
      state.budget == 0 ->
        {:reply, {:error, "Tool call budget exhausted"}, %{state | failed: true}}

      state.failed or state.terminal != nil ->
        {:reply, {:error, "Execution is sealed"}, state}

      true ->
        execute(command, %{state | budget: state.budget - 1})
    end
  end

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  defp execute({:operation, name}, state) do
    case Map.fetch(state.execution.operations, name) do
      {:ok, callback} ->
        case Map.fetch(state.results, name) do
          {:ok, value} -> {:reply, {:ok, value}, state}
          :error -> invoke(name, callback, state)
        end

      :error ->
        {:reply, {:error, "Operation is not admitted"}, %{state | failed: true}}
    end
  end

  defp execute({:complete, derived}, state) do
    if map_size(state.results) == map_size(state.execution.operations) do
      verify = Map.get(state.execution, :verify, fn _results, _derived -> true end)

      if :erlang.external_size(derived) <= 65_536 and verify.(state.results, derived) do
        terminal = state.execution.result.(state.results)
        {:reply, {:ok, "Native result ready"}, %{state | terminal: terminal}}
      else
        {:reply, {:error, "Derived result failed native verification"}, %{state | failed: true}}
      end
    else
      {:reply, {:error, "Run every required operation before completing"}, state}
    end
  rescue
    _exception -> {:reply, {:error, "Result mapping failed"}, %{state | failed: true}}
  catch
    _kind, _reason -> {:reply, {:error, "Result mapping failed"}, %{state | failed: true}}
  end

  defp invoke(name, callback, state) do
    case callback.() do
      {:ok, value} ->
        # Only bounded, serializable values cross the generated-code boundary.
        if :erlang.external_size(value) <= 65_536 do
          _json = Jason.encode!(value)
          {:reply, {:ok, value}, %{state | results: Map.put(state.results, name, value)}}
        else
          {:reply, {:error, "Native result exceeds limit"}, %{state | failed: true}}
        end

      _other ->
        {:reply, {:error, "Native operation failed"}, %{state | failed: true}}
    end
  rescue
    _exception -> {:reply, {:error, "Native operation failed"}, %{state | failed: true}}
  catch
    _kind, _reason -> {:reply, {:error, "Native operation failed"}, %{state | failed: true}}
  end
end
