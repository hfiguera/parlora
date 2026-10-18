defmodule Parlora.AudioValidation do
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Event, ID, Limits, Pacer}
  alias Parlora.Channels.LocalAudio

  def run do
    host = System.fetch_env!("CPAL_HOST")
    {:ok, devices} = LocalAudio.devices(host)
    input = device(devices, System.fetch_env!("CPAL_INPUT"), :input)
    output = device(devices, System.fetch_env!("CPAL_OUTPUT"), :output)

    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, pid} =
      LocalAudio.start_link(init, host: host, input_device: input.id, output_device: output.id)

    receive do
      {:parlora_event, %Event{type: :ready}} -> :ok
    after
      5_000 -> raise "Audio startup timed out"
    end

    try do
      baseline = phase(pid, 50, false, 0)
      warm = LocalAudio.observations(pid)
      blocks = String.to_integer(System.get_env("CPAL_TONE_BLOCKS", "100"))
      playing = phase(pid, blocks, true, 0)
      queued = LocalAudio.observations(pid)
      :ok = LocalAudio.control(pid, "suppress", {:suppress_output, true})
      {clear_us, :ok} = :timer.tc(fn -> LocalAudio.control(pid, "clear", {:clear_output, 1}) end)
      stopped = phase(pid, 50, false, 1)
      :ok = LocalAudio.control(pid, "resume", {:suppress_output, false})
      resumed = phase(pid, blocks, true, 1)
      final = LocalAudio.observations(pid)

      {close_us, :ok} =
        :timer.tc(fn ->
          :ok = LocalAudio.close(pid, "close", :validation)

          receive do
            {:parlora_event, %Event{type: :closed}} -> :ok
          after
            4_000 -> raise "Audio close timed out"
          end
        end)

      amplitudes = %{
        baseline: window_amplitude(baseline),
        playing: window_amplitude(playing),
        stopped_tail: window_amplitude(drop_ms(stopped, 200)),
        resumed: window_amplitude(resumed)
      }

      windows = for <<window::binary-size(960) <- stopped>>, do: amplitude(window)

      tail_ms =
        windows
        |> Enum.with_index()
        |> Enum.filter(fn {value, _index} -> value > max(5, amplitudes.playing / 10) end)
        |> Enum.map(fn {_value, index} -> (index + 1) * 20 end)
        |> Enum.max(fn -> 0 end)

      IO.inspect(
        %{
          host: host,
          input_format: input.input,
          output_format: output.output,
          clear_us: clear_us,
          close_us: close_us,
          approximate_capture_tail_ms: tail_ms,
          native_queue_before_clear: queued.output_queued,
          warm: warm,
          final: final,
          tone_amplitudes: amplitudes
        },
        label: "INTEGRATED_AUDIO"
      )

      if final.errors != 0 or final.dropped != warm.dropped,
        do: raise("Native audio errors or capture drops")

      if amplitudes.resumed < max(2, amplitudes.baseline * 2),
        do: raise("Resumed tone not recovered from capture")

      if System.get_env("CPAL_VIRTUAL_LOOPBACK") == "1" and amplitudes.playing < 700,
        do: raise("Virtual tone recovery amplitude too low")
    after
      GenServer.stop(pid)
    end
  end

  defp device(devices, name, direction),
    do:
      Enum.find(devices, &(&1.name == name and Map.fetch!(&1, direction) != nil)) ||
        raise("Device not found")

  defp phase(pid, blocks, tone?, epoch) do
    start = System.monotonic_time(:microsecond)

    {chunks, _deadline} =
      Enum.map_reduce(0..(blocks - 1), start, fn index, deadline ->
        pcm =
          for sample <- 0..239, into: <<>> do
            value =
              if tone?,
                do:
                  round(1_000 * :math.sin(2 * :math.pi() * 440 * (index * 240 + sample) / 24_000)),
                else: 0

            <<value::signed-little-16>>
          end

        :ok =
          LocalAudio.write_audio(
            pid,
            AudioFrame.pcm(pcm, "validation", index, playback_epoch: epoch)
          )

        {:ok, frames} = LocalAudio.read_audio(pid, 9_600)
        {next_deadline, wait_ms} = Pacer.next(deadline, 10_000)
        Process.sleep(wait_ms)
        {Enum.map(frames, & &1.data), next_deadline}
      end)

    IO.iodata_to_binary(chunks)
  end

  defp drop_ms(pcm, ms) do
    bytes = min(byte_size(pcm), ms * 48)
    binary_part(pcm, bytes, byte_size(pcm) - bytes)
  end

  defp window_amplitude(pcm) do
    values = for <<window::binary-size(960) <- pcm>>, do: amplitude(window)
    if values == [], do: 0.0, else: Enum.sum(values) / length(values)
  end

  defp amplitude(<<>>), do: 0.0

  defp amplitude(pcm) do
    values = for <<sample::signed-little-16 <- pcm>>, do: sample

    {sine, cosine} =
      values
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {value, index}, {sine, cosine} ->
        phase = 2 * :math.pi() * 440 * index / 24_000
        {sine + value * :math.sin(phase), cosine + value * :math.cos(phase)}
      end)

    2 * :math.sqrt(sine * sine + cosine * cosine) / length(values)
  end
end

Parlora.AudioValidation.run()
