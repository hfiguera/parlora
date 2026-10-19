defmodule Parlora.PlayoutValidation do
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioPipeline, ID, Limits}
  alias Parlora.TestSupport.MemoryAudio
  alias Parlora.Channels.LocalAudio

  def handle(_event, measurements, _metadata, table) do
    :ets.insert(
      table,
      {System.unique_integer([:positive, :monotonic]), System.monotonic_time(:microsecond),
       measurements}
    )
  end

  defp options do
    host = System.get_env("CPAL_HOST", "CoreAudio")
    buffer = String.to_integer(System.get_env("PARLORA_PLAYBACK_BUFFER_MS", "60"))
    {:ok, devices} = LocalAudio.devices(host)

    Enum.reduce(
      [{:input_device, "CPAL_INPUT", :input}, {:output_device, "CPAL_OUTPUT", :output}],
      [host: host, playback_buffer_ms: buffer],
      fn {key, env, direction}, options ->
        case System.get_env(env) do
          nil ->
            options

          name ->
            device =
              Enum.find(devices, &(&1.name == name and Map.fetch!(&1, direction) != nil)) ||
                raise("Device not found")

            Keyword.put(options, key, device.id)
        end
      end
    )
  end

  def run do
    table = :ets.new(:playout, [:ordered_set, :public])
    :telemetry.attach("probe", [:parlora, :audio, :playout], &__MODULE__.handle/4, table)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, source} =
      MemoryAudio.start_link(
        %{init | limits: %{init.limits | audio_queue_bytes: 24_000}},
        :provider,
        []
      )

    options = options()
    {:ok, dest} = LocalAudio.start_link(init, options)

    receive do
      {:parlora_event, %{source: :channel, type: :ready}} -> :ok
    after
      5000 -> raise "not ready"
    end

    {:ok, pipe} =
      AudioPipeline.start_link(
        init: init,
        direction: :output,
        source: {MemoryAudio, source},
        destination: {LocalAudio, dest}
      )

    try do
      exercise(source, dest, options, table)
    after
      for pid <- [pipe, dest, source], Process.alive?(pid), do: GenServer.stop(pid)
      :telemetry.detach("probe")
      :ets.delete(table)
    end
  end

  defp exercise(source, dest, options, table) do
    Process.sleep(200)
    baseline = LocalAudio.observations(dest)
    start = System.monotonic_time(:millisecond)

    for chunk <- 0..99 do
      # Continuous tone media, delivered in 100 ms network chunks with 20 ms jitter.
      at = start + chunk * 100 + if(rem(chunk, 2) == 1, do: 20, else: 0)
      Process.sleep(max(0, at - System.monotonic_time(:millisecond)))

      for frame <- 0..9 do
        seq = chunk * 10 + frame

        data =
          for n <- 0..239, into: <<>> do
            value = round(300 * :math.sin(2 * :math.pi() * 440 * (seq * 240 + n) / 24000))
            <<value::signed-little-16>>
          end

        :ok = MemoryAudio.audio(source, AudioFrame.pcm(data, "tone", seq))
      end

      {:ok, _} = LocalAudio.read_audio(dest, 9600)
    end

    Process.sleep(500)
    stats = LocalAudio.observations(dest)
    rows = :ets.tab2list(table)
    data = Enum.filter(rows, fn {_, _, m} -> m.source_bytes > 0 end)
    {_, first, _} = hd(data)
    {_, last, _} = List.last(data)
    gaps = Enum.filter(rows, fn {_, t, m} -> t >= first and t <= last and m.silence_bytes > 0 end)

    report = %{
      playback_buffer_ms: Keyword.fetch!(options, :playback_buffer_ms),
      source_ms: Enum.reduce(data, 0, fn {_, _, m}, s -> s + m.source_bytes / 48 end),
      gap_count: length(gaps),
      inserted_silence_ms: Enum.reduce(gaps, 0, fn {_, _, m}, s -> s + m.silence_bytes / 48 end),
      native_underrun_frames: stats.underrun,
      steady_native_underrun_frames: stats.underrun - baseline.underrun
    }

    IO.puts(JSON.encode!(report))
    if report.source_ms != 10000.0, do: raise("Source audio was not fully consumed")

    if report.playback_buffer_ms == 60 and report.gap_count != 0,
      do: raise("Playback cushion did not absorb test jitter")
  end
end

Parlora.PlayoutValidation.run()
