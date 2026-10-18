# Bounded 35-second live PCM source probe. No microphone, speaker or caller input.
defmodule ArrivalCapture do
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, ID, Limits}
  alias Parlora.Providers.OpenAI

  def record(_name, measurements, metadata, {session, table}) do
    if metadata.session_id == session do
      :ets.insert(table, {System.unique_integer([:positive, :monotonic]), measurements})
    end
  end

  def run do
    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: "arrival-probe",
      generation: 0,
      audio_format: %AudioFormat{},
      limits: %Limits{},
      event_sink: self()
    }

    table = :ets.new(:arrivals, [:ordered_set, :public])
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:parlora, :provider, :audio_received],
        &__MODULE__.record/4,
        {init.session_id, table}
      )

    {:ok, provider} =
      OpenAI.start_link(init,
        api_key: Application.fetch_env!(:parlora, :example_api_key),
        instructions:
          "Speak English. This is an audio timing test. Read each supplied sentence aloud once, then wait."
      )

    try do
      receive do
        {:parlora_event, %Event{type: :ready}} -> :ok
      after
        15_000 -> raise "Provider readiness timeout"
      end

      started = System.monotonic_time(:millisecond)
      pcm = loop(provider, started, 0, [], 0)
      :ok = OpenAI.close(provider, "capture-close", :validation)

      finalized =
        receive do
          {:parlora_event, %Event{type: :closed, payload: payload}} -> payload[:finalized?]
        after
          6_000 -> false
        end

      arrivals =
        Enum.map(:ets.tab2list(table), fn {_, m} ->
          Map.take(m, [:at_us, :bytes, :dropped_bytes])
        end)

      path = System.fetch_env!("PARLORA_CAPTURE_OUTPUT")
      pcm = pcm |> Enum.reverse() |> IO.iodata_to_binary()
      received_bytes = Enum.sum(Enum.map(arrivals, & &1.bytes))

      unless byte_size(pcm) == received_bytes and Enum.all?(arrivals, &(&1.dropped_bytes == 0)),
        do: raise("Capture did not retain every received source byte")

      File.write!(
        path,
        Jason.encode!(%{duration_limit_seconds: 35, finalized: finalized, arrivals: arrivals},
          pretty: true
        ) <> "\n"
      )

      File.write!(path <> ".pcm", pcm)

      IO.puts(
        Jason.encode!(%{
          packets: length(arrivals),
          finalized: finalized,
          bytes: Enum.sum(Enum.map(arrivals, & &1.bytes))
        })
      )

      unless finalized and length(arrivals) > 100, do: raise("Incomplete capture")
    after
      :telemetry.detach(handler)
      if Process.alive?(provider), do: GenServer.stop(provider)
      :ets.delete(table)
    end
  end

  defp loop(provider, started, tick, pcm, prompt) do
    elapsed = System.monotonic_time(:millisecond) - started

    if elapsed >= 35_000 do
      pcm
    else
      prompt =
        if prompt < 3 and elapsed >= prompt * 10_000 do
          :ok =
            OpenAI.append_context(provider, %ContextUpdate{
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

      :ok =
        OpenAI.write_audio(
          provider,
          AudioFrame.pcm(:binary.copy(<<0>>, 480), "silent-probe", tick)
        )

      {:ok, frames} = OpenAI.read_audio(provider, 9_600)
      pcm = Enum.reduce(frames, pcm, &[&1.data | &2])
      Process.sleep(max(0, started + (tick + 1) * 10 - System.monotonic_time(:millisecond)))
      loop(provider, started, tick + 1, pcm, prompt)
    end
  end
end

ArrivalCapture.run()
