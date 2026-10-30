# Real-service close classification; no caller audio or application mutations.
defmodule Parlora.PhonicShutdownLive do
  alias Parlora.{AdapterInit, AudioFormat, Event, Limits}
  alias Parlora.Providers.Phonic

  def run do
    path = System.argv() |> List.first() || "/tmp/parlora-phonic-shutdown-live.json"
    rows = for _repeat <- 1..3, format <- [%AudioFormat{}, AudioFormat.pcmu()], do: probe(format)
    File.write!(path, JSON.encode!(rows))
    IO.puts(JSON.encode!(%{probes: rows, report: path}))
  end

  defp probe(format) do
    session_id = Parlora.ID.new()

    init = %AdapterInit{
      session_id: session_id,
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: format,
      limits: %Limits{}
    }

    {:ok, pid} = Phonic.start_link(init, api_key: System.fetch_env!("PHONIC_API_KEY"))

    try do
      deadline = System.monotonic_time(:millisecond) + 15_000
      await_ready(session_id, deadline)
      conversation_id = await_id(pid, deadline)
      closed_at = System.system_time(:millisecond)
      started = System.monotonic_time(:millisecond)
      :ok = Phonic.close(pid, Parlora.ID.new(), :session_closed)
      close_ms = System.monotonic_time(:millisecond) - started
      await_closed(session_id)

      %{
        codec: format.codec,
        conversation_id: conversation_id,
        client_closed_at_ms: closed_at,
        close_call_ms: close_ms
      }
    after
      if Process.alive?(pid) do
        Phonic.close(pid, Parlora.ID.new(), :session_closed)
        GenServer.stop(pid, :normal)
      end
    end
  end

  defp await_id(pid, deadline) do
    state = :sys.get_state(pid)

    cond do
      is_binary(state.conversation_id) ->
        state.conversation_id

      System.monotonic_time(:millisecond) >= deadline ->
        raise("Provider conversation ID missing")

      true ->
        Process.sleep(10)
        await_id(pid, deadline)
    end
  end

  defp await_ready(id, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:parlora_event, %Event{session_id: ^id, type: :ready}} -> :ok
      {:parlora_event, %Event{session_id: ^id, type: :failed}} -> raise("Provider startup failed")
      _other -> await_ready(id, deadline)
    after
      remaining -> raise("Provider startup timed out")
    end
  end

  defp await_closed(id) do
    receive do
      {:parlora_event, %Event{session_id: ^id, type: :closed}} ->
        :ok

      {:parlora_event, %Event{session_id: ^id, type: :failed}} ->
        raise("Normal close emitted failure")
    after
      1_000 -> raise("Provider close event missing")
    end
  end
end

Parlora.PhonicShutdownLive.run()
