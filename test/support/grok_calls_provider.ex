defmodule Parlora.TestSupport.GrokCallsProvider do
  @moduledoc false
  use GenServer
  @behaviour Parlora.Provider
  alias Parlora.{Adapter, Event}
  alias Parlora.Providers.Grok.{Calls, Protocol}
  alias Parlora.TestSupport.MemoryAudio

  @impl true
  def start_link(init, options), do: GenServer.start_link(__MODULE__, {init, options})
  @impl true
  defdelegate capabilities(pid), to: MemoryAudio
  @impl true
  defdelegate read_audio(pid, budget), to: MemoryAudio
  @impl true
  defdelegate write_audio(pid, frame), to: MemoryAudio
  @impl true
  defdelegate control(pid, id, control), to: MemoryAudio
  @impl true
  defdelegate close(pid, id, reason), to: MemoryAudio
  @impl true
  def append_context(pid, update), do: Adapter.call(pid, {:routed_context, update})
  @impl true
  def resolve_delegation(pid, id, outcome), do: Adapter.call(pid, {:resolve, id, outcome})
  def delegate(pid, id), do: Adapter.call(pid, {:delegate, id})
  def records(pid), do: Adapter.call(pid, :records)

  @impl true
  def init({init, options}) do
    {:ok, state} = MemoryAudio.init({init, :provider, options})
    {:ok, Map.put(state, :calls, Calls.new(init.limits.max_records))}
  end

  @impl true
  def handle_info(message, state), do: MemoryAudio.handle_info(message, state)

  @impl true
  def handle_call(:records, _from, state), do: {:reply, state.calls.records, state}

  def handle_call({:delegate, id}, _from, state) do
    call = %{
      "call_id" => id,
      "name" => Protocol.function(),
      "arguments" => Jason.encode!(%{request: "Check an order"})
    }

    {:new, _, calls} = Calls.admit(state.calls, call)

    Event.emit(state.init, :provider, :delegation_requested, %{
      id: id,
      target: :client,
      offset_ms: 0
    })

    {:reply, :ok, %{state | calls: calls}}
  end

  def handle_call({:resolve, id, outcome}, _from, state) do
    case Calls.complete(state.calls, id, outcome) do
      {:ok, _command, calls} -> {:reply, :ok, %{state | calls: calls}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:routed_context, update}, from, state) do
    case Calls.context(state.calls, update.delegation_id, update.content) do
      {:ok, _command, calls} ->
        MemoryAudio.handle_call({:command, update.id, {:context, update}}, from, %{
          state
          | calls: calls
        })

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(message, from, state), do: MemoryAudio.handle_call(message, from, state)
end
