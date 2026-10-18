defmodule OpusCodecTest do
  use ExUnit.Case

  defp codec(kind, rate \\ 24_000, channels \\ 1) do
    {:ok, ref} = OpusProbe.new(kind, rate, channels, 2048)
    on_exit(fn -> :ok = OpusProbe.close(ref) end)
    ref
  end

  defp tone(rate, channels, index, samples) do
    for i <- 0..(samples - 1), channel <- 1..channels, into: <<>> do
      value =
        round(
          8_000 *
            :math.sin(
              2 * :math.pi() * (220 + channel * 220) *
                (index * samples + i) / rate
            )
        )

      <<value::signed-little-16>>
    end
  end

  defp packets(encoder, count) do
    Enum.map(0..(count - 1), fn index ->
      {:ok, packet} = OpusProbe.encode(encoder, tone(24_000, 1, index, 480), 480)
      packet
    end)
  end

  test "exact native and BEAM versions" do
    assert to_string(OpusProbe.version()) == "libopus 1.6.1"
    assert System.version() == "1.20.4"
    otp = Path.join([to_string(:code.root_dir()), "releases", "29", "OTP_VERSION"])
    assert File.read!(otp) |> String.trim() == "29.1.2"
  end

  test "mono and stereo at all supported rates and standard frame durations" do
    for rate <- [8_000, 12_000, 16_000, 24_000, 48_000],
        channels <- [1, 2],
        factor <- [1, 2, 4, 8, 16, 24] do
      encoder = codec(:encoder, rate, channels)
      decoder = codec(:decoder, rate, channels)
      samples = div(rate, 400) * factor
      {:ok, packet} = OpusProbe.encode(encoder, tone(rate, channels, 0, samples), samples)
      assert {^samples, _, _} = OpusProbe.packet_info(packet, rate)
      assert {:ok, pcm, ^samples} = OpusProbe.decode(decoder, packet, samples, 0)
      assert byte_size(pcm) == samples * channels * 2
    end
  end

  test "independent stereo input becomes 24 kHz mono with both tones present" do
    bytes = File.read!(Path.expand("fixtures/stereo-opus.bin", __DIR__))

    packets =
      Stream.unfold(bytes, fn
        <<>> -> nil
        <<length::32, packet::binary-size(length), rest::binary>> -> {packet, rest}
      end)

    decoder = codec(:decoder)

    pcm =
      Enum.map_join(packets, fn packet ->
        {:ok, frame, 480} = OpusProbe.decode(decoder, packet, 480, 0)
        frame
      end)

    samples = for <<sample::signed-little-16 <- pcm>>, do: sample
    assert length(samples) == 9_600
    # Skip startup codec delay; test coherent signal, not just nonzero noise.
    signal = Enum.drop(samples, 960)

    amplitude = fn frequency ->
      {real, imaginary} =
        signal
        |> Enum.with_index()
        |> Enum.reduce({0.0, 0.0}, fn {s, i}, {r, im} ->
          angle = 2 * :math.pi() * frequency * i / 24_000
          {r + s * :math.cos(angle), im + s * :math.sin(angle)}
        end)

      2 * :math.sqrt(real * real + imaginary * imaginary) / length(signal)
    end

    assert amplitude.(440) > 2_000
    assert amplitude.(660) > 2_000
    assert amplitude.(1_000) < 500
  end

  test "voice controls are applied and DTX produces short silence packets" do
    encoder = codec(:encoder)
    assert :ok = OpusProbe.configure(encoder, 24_000, 5, 1, 20, 1, 1103)
    assert {24_000, 5, 1, 20, 1, 2048} = OpusProbe.settings(encoder)

    sizes =
      for _ <- 1..100 do
        {:ok, packet} = OpusProbe.encode(encoder, :binary.copy(<<0>>, 960), 480)
        byte_size(packet)
      end

    assert Enum.any?(sizes, &(&1 <= 2))
  end

  test "packet loss concealment and subsequent decoding preserve duration" do
    encoder = codec(:encoder)
    [first, _lost, third] = packets(encoder, 3)
    decoder = codec(:decoder)
    assert {:ok, _, 480} = OpusProbe.decode(decoder, first, 480, 0)
    assert {:ok, concealment, 480} = OpusProbe.decode(decoder, nil, 480, 0)
    assert byte_size(concealment) == 960
    assert {:ok, _, 480} = OpusProbe.decode(decoder, third, 480, 0)
  end

  test "FEC exists in the packet and recovers a dropped frame before normal decoding" do
    encoder = codec(:encoder)
    :ok = OpusProbe.configure(encoder, 20_000, 10, 1, 30, 0, 1103)
    packets = packets(encoder, 50)
    # Confirm actual redundancy, rather than accepting libopus's PLC fallback as FEC.
    index =
      Enum.find(2..49, fn i ->
        match?({480, 1, 1}, OpusProbe.packet_info(Enum.at(packets, i), 24_000))
      end)

    assert index != nil
    recovery = codec(:decoder)
    concealment = codec(:decoder)

    for packet <- Enum.take(packets, index - 1), decoder <- [recovery, concealment] do
      assert {:ok, _, 480} = OpusProbe.decode(decoder, packet, 480, 0)
    end

    next = Enum.at(packets, index)
    assert {:ok, recovered_pcm, 480} = OpusProbe.decode(recovery, next, 480, 1)
    assert {:ok, concealed_pcm, 480} = OpusProbe.decode(concealment, nil, 480, 0)
    assert recovered_pcm != concealed_pcm
    assert {:ok, _, 480} = OpusProbe.decode(recovery, next, 480, 0)
  end

  test "requesting unavailable FEC falls back to concealment" do
    encoder = codec(:encoder)
    :ok = OpusProbe.configure(encoder, 20_000, 5, 0, 0, 0, 1103)
    [first, _lost, third] = packets(encoder, 3)
    assert {480, 1, 0} = OpusProbe.packet_info(third, 24_000)
    a = codec(:decoder)
    b = codec(:decoder)
    for decoder <- [a, b], do: assert({:ok, _, 480} = OpusProbe.decode(decoder, first, 480, 0))
    assert {:ok, pcm, 480} = OpusProbe.decode(a, third, 480, 1)
    assert {:ok, ^pcm, 480} = OpusProbe.decode(b, nil, 480, 0)
  end

  test "invalid calls, corrupted packets, and closed resources return safely" do
    encoder = codec(:encoder)
    decoder = codec(:decoder)
    assert_raise ArgumentError, fn -> OpusProbe.new(:encoder, 44_100, 1, 2048) end
    assert_raise ArgumentError, fn -> OpusProbe.new(:decoder, 24_000, 3, 2048) end
    assert_raise ArgumentError, fn -> OpusProbe.encode(encoder, <<0>>, 480) end
    assert_raise ArgumentError, fn -> OpusProbe.encode(encoder, <<0>>, -1) end
    assert_raise ArgumentError, fn -> OpusProbe.decode(decoder, <<>>, 480, 0) end
    assert_raise ArgumentError, fn -> OpusProbe.decode(decoder, nil, 1_000_000, 0) end

    assert_raise ArgumentError, fn ->
      OpusProbe.decode(decoder, :binary.copy(<<0>>, 8193), 480, 0)
    end

    assert_raise ArgumentError, fn -> OpusProbe.configure(encoder, 24_000, 11, 0, 0, 0, 1103) end
    assert {:error, -4} = OpusProbe.decode(decoder, <<3>>, 480, 0)

    assert {:error, :closed_or_wrong_kind} =
             OpusProbe.encode(decoder, :binary.copy(<<0>>, 960), 480)

    assert :ok = OpusProbe.close(encoder)
    assert :ok = OpusProbe.close(encoder)

    assert {:error, :closed_or_wrong_kind} =
             OpusProbe.encode(encoder, :binary.copy(<<0>>, 960), 480)

    assert {:error, :closed_or_wrong_kind} = OpusProbe.reset(encoder)
  end

  test "bounded randomized packet input does not crash the binding" do
    :rand.seed(:exsss, {41, 42, 43})
    decoder = codec(:decoder, 48_000, 2)

    for _ <- 1..1_000 do
      bytes = for _ <- 1..:rand.uniform(256), into: <<>>, do: <<:rand.uniform(256) - 1>>

      case OpusProbe.decode(decoder, bytes, 5760, 0) do
        {:ok, pcm, samples} -> assert byte_size(pcm) == samples * 4 and samples <= 5760
        {:error, code} -> assert is_integer(code) and code < 0
      end

      :ok = OpusProbe.reset(decoder)
    end
  end

  test "reset is deterministic and simultaneous use is serialized or rejected" do
    encoder = codec(:encoder)
    pcm = tone(24_000, 1, 0, 480)
    {:ok, first} = OpusProbe.encode(encoder, pcm, 480)
    :ok = OpusProbe.reset(encoder)
    assert {:ok, ^first} = OpusProbe.encode(encoder, pcm, 480)

    results =
      1..256
      |> Task.async_stream(fn _ -> OpusProbe.encode(encoder, pcm, 480) end,
        max_concurrency: 32
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.any?(results, &match?({:ok, _}, &1))

    assert Enum.all?(
             results,
             &(match?({:ok, packet} when is_binary(packet), &1) or &1 == {:error, :busy})
           )
  end

  test "resource cleanup and early process exits" do
    for _ <- 1..100 do
      task =
        Task.async(fn ->
          for _ <- 1..10 do
            {:ok, encoder} = OpusProbe.new(:encoder, 24_000, 1, 2048)
            {:ok, _} = OpusProbe.encode(encoder, :binary.copy(<<0>>, 960), 480)
            # Drop references without close to exercise the resource destructor.
          end
        end)

      Task.await(task)
    end

    :erlang.garbage_collect()
  end

  @tag timeout: 60_000
  test "eight independent streams encode and decode 160 seconds of audio" do
    started = System.monotonic_time(:microsecond)

    durations =
      1..8
      |> Task.async_stream(
        fn _ ->
          {:ok, encoder} = OpusProbe.new(:encoder, 24_000, 1, 2048)
          {:ok, decoder} = OpusProbe.new(:decoder, 24_000, 1, 2048)

          try do
            for i <- 0..999 do
              pcm = tone(24_000, 1, i, 480)

              {elapsed, _} =
                :timer.tc(fn ->
                  {:ok, packet} = OpusProbe.encode(encoder, pcm, 480)
                  {:ok, output, 480} = OpusProbe.decode(decoder, packet, 480, 0)
                  assert byte_size(output) == 960
                end)

              elapsed
            end
          after
            :ok = OpusProbe.close(encoder)
            :ok = OpusProbe.close(decoder)
          end
        end,
        max_concurrency: 8,
        timeout: 60_000
      )
      |> Enum.flat_map(fn {:ok, times} -> times end)
      |> Enum.sort()

    assert length(durations) == 8_000
    wall = (System.monotonic_time(:microsecond) - started) / 1_000_000

    IO.puts(
      "OPUS_LOAD wall_seconds=#{Float.round(wall, 3)} pairs=8000 " <>
        "p50_us=#{Enum.at(durations, 3999)} p95_us=#{Enum.at(durations, 7599)} p99_us=#{Enum.at(durations, 7919)}"
    )
  end
end
