defmodule Parlora.TestSupport.FakeBackend do
  @moduledoc false
  use GenServer
  @behaviour Parlora.Backend
  alias Parlora.{Adapter, BackendResult, CommandLog, Error, Event}

  @impl true
  def start_link(init, options), do: GenServer.start_link(__MODULE__, {init, options})
  @impl true
  def capabilities(pid), do: Adapter.call(pid, :capabilities)
  @impl true
  def submit(pid, request), do: Adapter.call(pid, {:submit, request})
  @impl true
  def update(pid, id, request_id, replacement),
    do: Adapter.call(pid, {:update, id, request_id, replacement})

  @impl true
  def cancel(pid, id, request_id, reason),
    do: Adapter.call(pid, {:cancel, id, request_id, reason})

  @impl true
  def close(pid, id, reason), do: Adapter.call(pid, {:close, id, reason})

  def complete(pid, request, summary, status \\ :completed),
    do: Adapter.call(pid, {:complete, request, summary, status})

  def inject(pid, type, payload, fields), do: Adapter.call(pid, {:inject, type, payload, fields})

  @impl true
  def init({init, options}) do
    observer = Keyword.fetch!(options, :observer)
    send(observer, {:adapter, :backend, self()})

    caps =
      Keyword.get(options, :capabilities, %Parlora.Backend.Capabilities{cancellation: :advisory})

    Event.emit(init, :backend, :ready, %{capabilities: caps})
    {:ok, %{init: init, observer: observer, caps: caps, commands: %CommandLog{}, closed: false}}
  end

  @impl true
  def handle_call(:capabilities, _from, state), do: {:reply, {:ok, state.caps}, state}

  def handle_call({:submit, request}, _from, state) do
    case CommandLog.admit(state.commands, request.id, request) do
      {:new, commands} ->
        send(state.observer, {:submitted, request})

        Event.emit(
          state.init,
          :backend,
          :request_started,
          %{task_revision: request.task_revision},
          request_id: request.id
        )

        {:reply, :ok, %{state | commands: commands}}

      {:duplicate, _commands} ->
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:inject, type, payload, fields}, _from, state) do
    Event.emit(state.init, :backend, type, payload, fields)
    {:reply, :ok, state}
  end

  def handle_call({:update, id, _request_id, replacement}, _from, state) do
    if state.caps.updates? do
      send(state.observer, {:updated, id, replacement})
      {:reply, :ok, state}
    else
      {:reply, Error.tuple(:unsupported, "Updates unsupported"), state}
    end
  end

  def handle_call({:complete, request, summary, status}, _from, state) do
    result = %BackendResult{
      request_id: request.id,
      task_id: request.task_id,
      task_revision: request.task_revision,
      provider_generation: request.provider_generation,
      summary: summary,
      status: status,
      facts: request.input
    }

    type =
      Map.fetch!(
        %{completed: :request_completed, failed: :request_failed, cancelled: :request_cancelled},
        status
      )

    Event.emit(state.init, :backend, type, result, request_id: request.id)
    {:reply, :ok, state}
  end

  def handle_call({:cancel, id, request_id, _reason}, _from, state) do
    Event.emit(state.init, :backend, :cancellation_requested, %{},
      command_id: id,
      request_id: request_id
    )

    {:reply, :ok, state}
  end

  def handle_call({:close, id, _reason}, _from, state) do
    Event.emit(state.init, :backend, :closed, %{}, command_id: id)
    {:reply, :ok, %{state | closed: true}}
  end
end
