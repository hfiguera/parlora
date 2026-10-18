defmodule OptionalBackendConsumer do
  @moduledoc false
  alias Parlora.{ContextUpdate, Event}

  alias Parlora.TestSupport.{
    ContractProvider,
    FakeBackend,
    MemoryAudio,
    MemoryChannel,
    OrderPolicy
  }

  def check_dependencies! do
    profile = Application.fetch_env!(:optional_backend_consumer, :profile)

    for {app, module} <- [{:jido, Jido.AgentServer}, {:sagents, Sagents.Agent}, {:legion, Legion}] do
      if app == profile do
        true = Code.ensure_loaded?(module)
      else
        {:error, :bad_name} = :code.lib_dir(app)
        false = Code.ensure_loaded?(module)
      end
    end

    :ok
  end

  def smoke do
    :ok = check_dependencies!()

    {:ok, session} =
      Parlora.start_session(
        channel: {MemoryChannel, observer: self()},
        provider: {ContractProvider, observer: self()},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, []},
        event_sink: self()
      )

    ref = Process.monitor(session)

    try do
      provider = adapter(:provider)
      backend = adapter(:backend)
      event(:ready)
      :ok = MemoryAudio.inject(provider, :delegation_requested, %{id: "custom", offset_ms: nil})

      :ok =
        MemoryAudio.inject(provider, :transcript_delta, %{
          speaker: :user,
          delta: "order 124",
          start_ms: nil,
          end_ms: nil
        })

      request =
        receive do
          {:submitted, request} -> request
        after
          5_000 -> raise "Custom backend request was not submitted"
        end

      :ok = FakeBackend.complete(backend, request, "Verified custom backend result")

      receive do
        {:context, %ContextUpdate{content: "Verified custom backend result"}} -> :ok
      after
        5_000 -> raise "Custom backend result did not reach the provider"
      end

      :ok = Parlora.close(session)

      event(:closed)

      receive do
        {:DOWN, ^ref, :process, ^session, :normal} -> :ok
      after
        5_000 -> raise "Session did not stop"
      end

      IO.puts("OPTIONAL_BACKEND_CONSUMER: dependency isolation and custom session passed")
    after
      if Process.alive?(session), do: Parlora.close(session)
      Process.demonitor(ref, [:flush])
    end
  end

  defp adapter(role) do
    receive do
      {:adapter, ^role, pid} -> pid
    after
      5_000 -> raise "Missing #{role} adapter"
    end
  end

  defp event(type) do
    receive do
      {:parlora_event, %Event{source: :session, type: ^type}} -> :ok
    after
      5_000 -> raise "Missing session #{type} event"
    end
  end
end
