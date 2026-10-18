# Controlled generated-output capture. No microphone or real caller content.
defmodule Parlora.Validation.ArrivalWindow do
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, ID, Limits}

  @row_limit 12_000

  def record(_name, measurements, metadata, {session, table}) do
    if metadata.session_id == session do
      n = :ets.update_counter(table, :count, 1)
      if n <= @row_limit, do: :ets.insert(table, {n, measurements})
    end
  end

  def run do
    provider = Application.fetch_env!(:parlora, :example_provider)
    Code.ensure_loaded!(provider)
    seconds = String.to_integer(System.get_env("PARLORA_CAPTURE_SECONDS", "45"))
    unless seconds in 15..60, do: raise("Capture duration must be 15..60 seconds")
    output = System.fetch_env!("PARLORA_CAPTURE_OUTPUT")

    limits =
      if function_exported?(provider, :audio_limits, 1),
        do: provider.audio_limits(%AudioFormat{}),
        else: []

    {:ok, limits} = Limits.new(limits)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: "arrival-window",
      generation: 0,
      audio_format: %AudioFormat{},
      limits: limits,
      event_sink: self()
    }

    table = :ets.new(:arrival_window, [:ordered_set, :public])
    :ets.insert(table, {:count, 0})
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:parlora, :provider, :audio_received],
        &__MODULE__.record/4,
        {init.session_id, table}
      )

    {:ok, pid} =
      provider.start_link(init,
        api_key: Application.fetch_env!(:parlora, :example_api_key),
        instructions:
          "Speak English. This is an audio timing test. Read each supplied sentence once, then wait."
      )

    try do
      receive do
        {:parlora_event, %Event{type: :ready}} -> :ok
        {:parlora_event, %Event{type: :failed}} -> raise("Provider startup failed")
      after
        15_000 -> raise("Provider readiness timeout")
      end

      started = System.monotonic_time(:millisecond)
      {parts, failure} = loop(provider, pid, started, seconds * 1_000, 0, [], 0)

      # Seal receipt observations and retain queued output in the provider's own
      # serialized turn. Otherwise a close-round-trip can add arrivals after the
      # reader stops, falsely failing (or truncating) byte accounting.
      caller = self()

      _state =
        :sys.replace_state(pid, fn state ->
          :telemetry.detach(handler)
          {frames, queue} = Parlora.AudioQueue.pop(state.inbound, state.inbound.capacity)
          send(caller, {:capture_tail, frames})
          %{state | inbound: queue}
        end)

      tail =
        receive do
          {:capture_tail, frames} -> Enum.map_join(frames, & &1.data)
        after
          1_000 -> raise("Capture fence timed out")
        end

      pcm = IO.iodata_to_binary([Enum.reverse(parts), tail])
      count = :ets.lookup_element(table, :count, 2)
      arrivals = for {key, m} <- :ets.tab2list(table), is_integer(key), do: m
      first = if arrivals == [], do: 0, else: hd(arrivals).at_us
      arrivals = Enum.map(arrivals, &Map.update!(&1, :at_us, fn at -> at - first end))
      received = Enum.sum(Enum.map(arrivals, & &1.bytes))
      dropped = Enum.sum(Enum.map(arrivals, & &1.dropped_bytes))

      valid =
        failure == nil and count <= @row_limit and count > 0 and received > 0 and
          received == byte_size(pcm) and
          dropped == 0

      File.write!(
        output,
        Jason.encode!(
          %{
            provider: inspect(provider),
            capture_seconds: seconds,
            row_limit: @row_limit,
            complete: valid,
            failure: failure,
            received_bytes: received,
            retained_bytes: byte_size(pcm),
            dropped_bytes: dropped,
            arrivals: arrivals
          },
          pretty: true
        ) <> "\n"
      )

      File.write!(output <> ".pcm", pcm)

      IO.puts(
        Jason.encode!(%{
          provider: inspect(provider),
          packets: count,
          received_bytes: received,
          retained_bytes: byte_size(pcm),
          dropped_bytes: dropped,
          complete: valid
        })
      )

      unless valid, do: raise("Incomplete arrival capture; failure evidence preserved")
      :ok = provider.close(pid, ID.new(), :validation)

      receive do
        {:parlora_event, %Event{type: :closed}} -> :ok
      after
        6_000 -> raise("Provider close not observed")
      end
    after
      :telemetry.detach(handler)
      if Process.alive?(pid), do: GenServer.stop(pid)
      :ets.delete(table)
    end
  end

  defp loop(provider, pid, started, duration, tick, parts, prompt) do
    elapsed = System.monotonic_time(:millisecond) - started

    if elapsed >= duration do
      {parts, nil}
    else
      resume_interruptions(provider, pid)
      prompt_limit = if provider == Parlora.Providers.OpenAI, do: 3, else: 1

      prompt =
        if prompt < prompt_limit and elapsed >= prompt * 10_000 do
          :ok =
            provider.append_context(pid, %ContextUpdate{
              id: ID.new(),
              kind: :speakable,
              provider_generation: 0,
              content:
                "Read aloud: Your order contains one desk lamp. It is out for delivery today. Please check the delivery instructions and confirm the exact text before saving a change."
            })

          prompt + 1
        else
          prompt
        end

      with :ok <-
             provider.write_audio(
               pid,
               AudioFrame.pcm(:binary.copy(<<0>>, 480), "silent-probe", tick)
             ),
           {:ok, frames} <- provider.read_audio(pid, 9_600) do
        parts = Enum.reduce(frames, parts, &[&1.data | &2])
        Process.sleep(max(0, started + (tick + 1) * 10 - System.monotonic_time(:millisecond)))
        loop(provider, pid, started, duration, tick + 1, parts, prompt)
      else
        {:error, error} -> {parts, error.code}
      end
    end
  end

  defp resume_interruptions(provider, pid) do
    receive do
      {:parlora_event, %Event{type: :output_interrupted, payload: %{token: token}}} ->
        :ok = provider.resume_output(pid, token)
        resume_interruptions(provider, pid)
    after
      0 -> :ok
    end
  end
end

Parlora.Validation.ArrivalWindow.run()
