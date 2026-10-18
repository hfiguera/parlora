defmodule Parlora.ProviderAudioTelemetryTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioQueue, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.{Gemini, Grok, OpenAI}

  def record(name, measurements, metadata, {owner, session}) do
    if metadata.session_id == session,
      do: send(owner, {:audio_measurement, name, measurements, metadata})
  end

  setup do
    handler = make_ref()
    session = Parlora.ID.new()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:parlora, :provider, :audio_received], [:parlora, :provider, :audio_read]],
        &__MODULE__.record/4,
        {self(), session}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, session: session}
  end

  test "receipt counts a whole packet once, with format-aware duration and explicit rejection",
       context do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      init = init(format, context.session)
      bytes = AudioFormat.bytes_for_ms(format, 100)
      queue = %AudioQueue{capacity: bytes}
      pcm = AudioFormat.silence(format, 100)
      {:ok, {queue, sequence}} = OutputBuffer.push(queue, pcm, init, 0, 10)
      assert sequence == 10

      assert_received {:audio_measurement, [:parlora, :provider, :audio_received],
                       %{
                         at_us: 10,
                         duration_us: 100_000,
                         bytes: ^bytes,
                         queue_before_bytes: 0,
                         queue_bytes: ^bytes,
                         dropped_bytes: 0
                       }, %{outcome: :accepted}}

      refute_received {:audio_measurement, [:parlora, :provider, :audio_received], _, _}

      assert {:error, %{code: :output_overflow}} =
               OutputBuffer.push(queue, pcm, init, sequence, 20)

      assert_received {:audio_measurement, [:parlora, :provider, :audio_received],
                       %{dropped_bytes: ^bytes, queue_bytes: ^bytes},
                       %{outcome: :output_overflow}}
    end
  end

  test "each provider reports queue reads using the same numeric schema without audio or secrets",
       context do
    init = init(%AudioFormat{}, context.session)

    {:ok, {queue, _}} =
      OutputBuffer.push(
        OutputBuffer.new(init.limits),
        AudioFormat.silence(init.audio_format, 100),
        init,
        0,
        System.monotonic_time(:microsecond)
      )

    for {provider, config} <- [{OpenAI, %{}}, {Gemini, %{setup: %{}, history: []}}, {Grok, %{}}] do
      {:ok, state, _continue} = provider.init({init, [api_key: "private-test-key"], config})
      state = %{state | status: :ready, inbound: queue}
      {:reply, {:ok, frames}, next} = provider.handle_call({:read, 960}, nil, state)
      assert Enum.reduce(frames, 0, &(byte_size(&1.data) + &2)) == 960
      assert next.inbound.bytes == 3_840

      assert_received {:audio_measurement, [:parlora, :provider, :audio_read], measurements,
                       metadata}

      assert Map.keys(measurements) |> Enum.sort() == [:at_us, :bytes, :queue_bytes]

      assert metadata == %{
               session_id: init.session_id,
               adapter_id: init.adapter_id,
               generation: 0
             }

      assert measurements.bytes == 960
      assert measurements.queue_bytes == 3_840
      refute inspect({measurements, metadata}) =~ "private-test-key"
    end
  end

  defp init(format, session) do
    %AdapterInit{
      session_id: session,
      adapter_id: "telemetry",
      generation: 0,
      audio_format: format,
      limits: %Limits{},
      event_sink: self()
    }
  end
end
