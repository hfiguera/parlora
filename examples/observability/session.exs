# Checkout-only fixtures belong to this development host, never the Hex package.
for name <- ~w(memory_audio memory_channel memory_provider fake_backend order_policy) do
  Code.require_file("../../test/support/#{name}.ex", __DIR__)
end

alias Parlora.TestSupport.{MemoryChannel, MemoryProvider, MemoryAudio, FakeBackend, OrderPolicy}
alias Parlora.Event

defmodule ParloraObserver.Demo do
  def run do
    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {MemoryProvider, observer: self()},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, []},
        event_sink: self()
      )

    id = Parlora.status(session).session_id
    reference = Process.monitor(session)

    provider =
      receive do
        {:adapter, :provider, pid} -> pid
      after
        15_000 -> raise "No provider"
      end

    backend =
      receive do
        {:adapter, :backend, pid} -> pid
      after
        15_000 -> raise "No backend"
      end

    receive do
      {:parlora_event, %Event{source: :session, type: :ready}} -> :ok
    after
      15_000 -> raise "Session not ready"
    end

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "private-observability-sentinel order 123",
      start_ms: 0,
      end_ms: 100
    })

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "demo",
      target: :client,
      offset_ms: 100
    })

    request =
      receive do
        {:submitted, request} -> request
      after
        5_000 -> raise "No request"
      end

    FakeBackend.complete(backend, request, "private-observability-sentinel result")

    receive do
      {:context, _update} -> :ok
    after
      5_000 -> raise "No delivery"
    end

    :ok = Parlora.close(session)

    receive do
      {:DOWN, ^reference, :process, ^session, :normal} -> :ok
    after
      10_000 -> raise "Session did not close"
    end

    id
  end
end
