defmodule CorrectionRouteProvider do
  use GenServer
  alias Parlora.TestSupport.MemoryAudio
  alias Parlora.Providers.Grok.Calls
  def start_link(init, options), do: GenServer.start_link(__MODULE__, {init, options})
  defdelegate capabilities(pid), to: MemoryAudio
  defdelegate read_audio(pid, budget), to: MemoryAudio
  defdelegate write_audio(pid, frame), to: MemoryAudio
  defdelegate control(pid, id, control), to: MemoryAudio
  defdelegate close(pid, id, reason), to: MemoryAudio
  def append_context(pid, update), do: GenServer.call(pid, {:routed_context, update})
  def resolve_delegation(pid, id, outcome), do: GenServer.call(pid, {:resolve, id, outcome})
  def delegate(pid), do: GenServer.call(pid, :delegate)
  def init({init, options}) do
    {:ok, state} = MemoryAudio.init({init, :provider, options})
    {:ok, Map.put(state, :calls, Calls.new(32))}
  end
  def handle_info(message, state), do: MemoryAudio.handle_info(message, state)
  def handle_call(:delegate, _from, state) do
    call = %{"call_id" => "original-call", "name" => Parlora.Providers.Grok.Protocol.function(), "arguments" => Jason.encode!(%{request: "order 123"})}
    {:new, _, calls} = Calls.admit(state.calls, call)
    Parlora.Event.emit(state.init, :provider, :delegation_requested, %{id: "original-call", target: :client, offset_ms: 0})
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
      {:ok, _command, calls} -> MemoryAudio.handle_call({:command, update.id, {:context, update}}, from, %{state | calls: calls})
      {:error, error} ->
        send(state.options[:observer], {:route_rejected, update.delegation_id, error})
        {:reply, {:error, error}, state}
    end
  end
  def handle_call(message, from, state), do: MemoryAudio.handle_call(message, from, state)
end

defmodule CorrectionRouteProbe do
  alias Parlora.TestSupport.{FakeBackend, MemoryAudio, MemoryChannel, OrderPolicy}
  def run do
    for order <- [:old_first, :current_first] do
      {:ok, session} = Parlora.start_session(channel: {MemoryChannel, observer: self()}, provider: {CorrectionRouteProvider, observer: self()}, backend: {FakeBackend, observer: self()}, context_policy: {OrderPolicy, []}, event_sink: self())
      provider = receive do {:adapter, :provider, p} -> p after 1_000 -> raise "No provider" end
      backend = receive do {:adapter, :backend, p} -> p after 1_000 -> raise "No backend" end
      receive do {:parlora_event, %{source: :session, type: :ready}} -> :ok after 1_000 -> raise "Not ready" end
      caption(provider, "order 123")
      :ok = CorrectionRouteProvider.delegate(provider)
      first = submitted()
      caption(provider, " actually order 124")
      second = submitted()
      true = first.delegation_id == second.delegation_id
      case order do
        :old_first ->
          FakeBackend.complete(backend, first, "Old order 123 answer")
          receive do {:parlora_event, %{type: :stale_result, request_id: id}} when id == first.id -> :ok after 1_000 -> raise "No stale result" end
          FakeBackend.complete(backend, second, "Correct order 124 answer")
          receive do {:route_rejected, id, error} -> IO.puts(Jason.encode!(%{order: order, reused_delegation: id, rejection: error.message, code: error.code})) after 1_000 -> raise "Expected rejection" end
        :current_first ->
          FakeBackend.complete(backend, second, "Correct order 124 answer")
          receive do {:context, %{content: "Correct order 124 answer"}} -> :ok after 1_000 -> raise "No current result" end
          FakeBackend.complete(backend, first, "Old order 123 answer")
          receive do {:parlora_event, %{type: :stale_result, request_id: id}} when id == first.id -> :ok after 1_000 -> raise "No stale result" end
      end
      snapshot = Parlora.status(session)
      IO.puts(Jason.encode!(%{order: order, corrected_status: snapshot.jobs[second.id].status, corrected_delivery: snapshot.jobs[second.id].delivery, provider_call_status: :sys.get_state(provider).calls.records["original-call"].status}))
      Parlora.close(session)
      receive do {:parlora_event, %{source: :session, type: :closed}} -> :ok after 1_000 -> :ok end
    end
  end
  defp submitted do
    receive do {:submitted, request} -> request after 1_000 -> raise "No admitted request" end
  end
  defp caption(provider, text), do: MemoryAudio.inject(provider, :transcript_delta, %{speaker: :user, delta: text, start_ms: 0, end_ms: 100})
end
CorrectionRouteProbe.run()
