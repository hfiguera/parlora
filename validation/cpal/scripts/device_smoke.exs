host = System.fetch_env!("CPAL_HOST")
input_name = System.fetch_env!("CPAL_INPUT")
output_name = System.fetch_env!("CPAL_OUTPUT")
loopback = System.get_env("CPAL_VIRTUAL_LOOPBACK") == "1"
devices = DeviceProbe.devices(host)

input =
  Enum.find(devices, &(&1.name == input_name and &1.input != nil)) || raise "input not found"

output =
  Enum.find(devices, &(&1.name == output_name and &1.output != nil)) || raise "output not found"

if loopback and not String.contains?(output.name, "Parlora"),
  do: raise("synthetic tone requires the named Parlora virtual device")

{:ok, ref} = DeviceProbe.open(host, input.id, output.id, 4800)

try do
  info = DeviceProbe.stats(ref)
  target_frames = div(info.output_rate, 20)
  # Feed by queue depth, not by assuming Process.sleep is an exact audio clock.
  # Hardware gets silence; only the named virtual sink receives a test tone.
  {chunks, {_position, warmup}} =
    Enum.map_reduce(0..399, {0, nil}, fn index, {position, warmup} ->
      warmup = if index == 100, do: DeviceProbe.stats(ref), else: warmup
      queued = DeviceProbe.stats(ref).output_queued
      frames = max(target_frames - queued, 0)

      if frames > 0 do
        pcm =
          for i <- 0..(frames - 1), _ <- 1..info.output_channels, into: <<>> do
            value =
              if loopback,
                do:
                  round(
                    1000 * :math.sin(2 * :math.pi() * 440 * (position + i) / info.output_rate)
                  ),
                else: 0

            <<value::signed-little-16>>
          end

        {:ok, written} = DeviceProbe.write(ref, pcm)
        if written != frames, do: raise("playback queue overflow")
      end

      {:ok, captured, _} = DeviceProbe.read(ref, 4800)
      Process.sleep(5)
      {captured, {position + frames, warmup}}
    end)

  received = IO.iodata_to_binary(chunks)

  live = DeviceProbe.stats(ref)
  {close_us, :ok} = :timer.tc(fn -> DeviceProbe.close(ref) end)
  stopped = DeviceProbe.stats(ref)
  Process.sleep(50)

  if not stopped.stopped or DeviceProbe.stats(ref) != stopped,
    do: raise("callbacks continued after close")

  IO.inspect(info, label: "OPEN")
  IO.inspect(warmup, label: "WARMUP")
  IO.inspect(live, label: "LIVE")
  if live.input_callbacks == 0 or live.output_callbacks == 0, do: raise("missing callbacks")
  if byte_size(received) == 0, do: raise("no captured PCM")
  if live.errors != 0, do: raise("CPAL stream errors")

  if live.dropped != warmup.dropped or live.underrun != warmup.underrun,
    do: raise("audio queue overrun or underrun after warmup")

  if loopback do
    values = for <<value::signed-little-16 <- received>>, do: value
    peak = values |> Enum.map(&abs/1) |> Enum.max()
    if peak < 500 or peak > 1500, do: raise("virtual playback was not recovered: peak #{peak}")

    mono =
      values
      |> Enum.take_every(info.input_channels)
      |> Enum.drop(div(info.input_rate, 2))
      |> Enum.take(div(info.input_rate, 2))

    {sine, cosine} =
      mono
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {value, i}, {sine, cosine} ->
        phase = 2 * :math.pi() * 440 * i / info.input_rate
        {sine + value * :math.sin(phase), cosine + value * :math.cos(phase)}
      end)

    amplitude = 2 * :math.sqrt(sine * sine + cosine * cosine) / length(mono)
    if amplitude < 800 or amplitude > 1200, do: raise("440 Hz loopback amplitude mismatch")

    IO.puts(
      "VIRTUAL_LOOPBACK peak=#{peak} tone_amplitude=#{Float.round(amplitude, 1)} samples=#{length(values)}"
    )
  end

  :ok = DeviceProbe.close(ref)
  IO.puts("DEVICE_SMOKE_PASS close_us=#{close_us} captured_bytes=#{byte_size(received)}")
after
  DeviceProbe.close(ref)
end
