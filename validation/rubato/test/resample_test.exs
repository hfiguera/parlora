defmodule ResampleProbeTest do
  use ExUnit.Case

  defp converter(input_rate, output_rate, input_channels, output_channels, chunk) do
    {:ok, ref} =
      ResampleProbe.new(input_rate, output_rate, input_channels, output_channels, chunk)

    on_exit(fn -> assert :ok = ResampleProbe.close(ref) end)
    ref
  end

  defp tone(rate, frames, frequencies, start \\ 0, amplitude \\ 8_000) do
    for i <- start..(start + frames - 1), frequency <- frequencies, into: <<>> do
      value = round(amplitude * :math.sin(2 * :math.pi() * frequency * i / rate))
      <<value::signed-little-16>>
    end
  end

  defp samples(pcm), do: for(<<sample::signed-little-16 <- pcm>>, do: sample)

  # Finite-stream helper: pad the last input block and drain the filter with zeros.
  # Remove startup delay ONCE and retain exactly the intended duration. A live
  # adapter must own this accounting and its bounded queues across callbacks.
  defp convert(pcm, input_rate, output_rate, input_channels, output_channels, chunk) do
    ref = converter(input_rate, output_rate, input_channels, output_channels, chunk)
    {^chunk, _, delay, _, _} = ResampleProbe.info(ref)
    frames = div(byte_size(pcm), input_channels * 2)
    expected = round(frames * output_rate / input_rate)
    block_bytes = chunk * input_channels * 2
    padding = rem(block_bytes - rem(byte_size(pcm), block_bytes), block_bytes)
    drain_blocks = ceil(256 / chunk) + 2
    padded = pcm <> :binary.copy(<<0>>, padding + drain_blocks * block_bytes)

    result =
      for <<block::binary-size(^block_bytes) <- padded>>, into: <<>> do
        {^chunk, next, _, _, _} = ResampleProbe.info(ref)
        {:ok, output, ^next} = ResampleProbe.process(ref, block)
        assert byte_size(output) == next * output_channels * 2
        output
      end

    assert byte_size(result) >= (delay + expected) * output_channels * 2
    binary_part(result, delay * output_channels * 2, expected * output_channels * 2)
  end

  defp rms(values) do
    :math.sqrt(Enum.reduce(values, 0.0, fn x, sum -> sum + x * x end) / length(values))
  end

  defp amplitude(values, rate, frequency) do
    {cosine, sine} =
      values
      |> Enum.with_index()
      |> Enum.reduce({0.0, 0.0}, fn {value, i}, {cosine, sine} ->
        phase = 2 * :math.pi() * frequency * i / rate
        {cosine + value * :math.cos(phase), sine + value * :math.sin(phase)}
      end)

    2 * :math.sqrt(cosine * cosine + sine * sine) / length(values)
  end

  test "pinned BEAM toolchain" do
    assert System.version() == "1.20.4"
    otp = Path.join([to_string(:code.root_dir()), "releases", "29", "OTP_VERSION"])
    assert String.trim(File.read!(otp)) == "29.1.2"
  end

  test "44.1 and 48 kHz capture to 24 kHz, and 24 kHz playback to both rates" do
    for {input_rate, output_rate} <- [
          {44_100, 24_000},
          {48_000, 24_000},
          {24_000, 44_100},
          {24_000, 48_000}
        ] do
      # An irregular ending forces partial-block padding and filter draining.
      frames = input_rate + 137
      pcm = tone(input_rate, frames, [1_000])
      output = convert(pcm, input_rate, output_rate, 1, 1, div(input_rate, 100))
      assert byte_size(output) == round(frames * output_rate / input_rate) * 2
      middle = output |> samples() |> Enum.slice(div(output_rate, 10), div(output_rate, 2))
      assert_in_delta amplitude(middle, output_rate, 1_000), 8_000, 16
      assert amplitude(middle, output_rate, 3_000) < 8
    end
  end

  test "downsampling preserves the voice passband and rejects above-Nyquist tones" do
    for input_rate <- [44_100, 48_000] do
      for frequency <- [100, 1_000, 8_000] do
        output =
          convert(
            tone(input_rate, input_rate, [frequency]),
            input_rate,
            24_000,
            1,
            1,
            div(input_rate, 100)
          )

        steady = output |> samples() |> Enum.slice(2_400, 19_200)
        gain = amplitude(steady, 24_000, frequency) / 8_000
        assert gain > 0.99 and gain < 1.01
      end

      for frequency <- [15_000, 18_000] do
        output =
          convert(
            tone(input_rate, input_rate, [frequency]),
            input_rate,
            24_000,
            1,
            1,
            div(input_rate, 100)
          )

        steady = output |> samples() |> Enum.slice(2_400, 19_200)
        ratio = rms(steady) / (8_000 / :math.sqrt(2))

        residual =
          if ratio == 0.0,
            do: "below_pcm16_resolution",
            else: "#{Float.round(20 * :math.log10(ratio), 1)}_dB"

        IO.puts("RUBATO_ALIAS input_rate=#{input_rate} tone_hz=#{frequency} residual=#{residual}")

        assert ratio < 0.001
      end
    end
  end

  test "stereo preservation, stereo to mono mixing, and mono duplication" do
    input = tone(44_100, 44_100, [440, 660])
    stereo = convert(input, 44_100, 24_000, 2, 2, 441)
    left = for <<l::signed-little-16, _r::signed-little-16 <- stereo>>, do: l
    right = for <<_l::signed-little-16, r::signed-little-16 <- stereo>>, do: r
    left = Enum.slice(left, 2_400, 19_200)
    right = Enum.slice(right, 2_400, 19_200)
    assert_in_delta amplitude(left, 24_000, 440), 8_000, 16
    assert amplitude(left, 24_000, 660) < 8
    assert_in_delta amplitude(right, 24_000, 660), 8_000, 16
    assert amplitude(right, 24_000, 440) < 8
    mono = convert(input, 44_100, 24_000, 2, 1, 441) |> samples() |> Enum.slice(2_400, 19_200)
    assert_in_delta amplitude(mono, 24_000, 440), 4_000, 16
    assert_in_delta amplitude(mono, 24_000, 660), 4_000, 16
    duplicated = convert(tone(24_000, 24_000, [440]), 24_000, 48_000, 1, 2, 240)
    assert Enum.all?(for(<<l::signed-little-16, r::signed-little-16 <- duplicated>>, do: l == r))
  end

  test "chunk boundaries do not change the resampled waveform" do
    pcm = tone(44_100, 44_237, [997])
    small = convert(pcm, 44_100, 24_000, 1, 1, 147)
    large = convert(pcm, 44_100, 24_000, 1, 1, 882)
    errors = Enum.zip_with(samples(small), samples(large), fn a, b -> abs(a - b) end)
    assert Enum.max(errors) <= 1
  end

  test "filter delay and end-of-stream tail are accounted for" do
    for {input_rate, output_rate} <- [{44_100, 24_000}, {48_000, 24_000}, {24_000, 48_000}] do
      chunk = div(input_rate, 100)
      ref = converter(input_rate, output_rate, 1, 1, chunk)
      {_, _, delay, _, _} = ResampleProbe.info(ref)

      IO.puts(
        "RUBATO_DELAY #{input_rate}->#{output_rate} frames=#{delay} ms=#{Float.round(1000 * delay / output_rate, 3)}"
      )

      assert delay > 0 and delay < output_rate / 100
      frames = input_rate + 137
      impulse_at = frames - div(input_rate, 1000)

      pcm =
        for i <- 0..(frames - 1),
            into: <<>>,
            do: <<if(i == impulse_at, do: 16_000, else: 0)::signed-little-16>>

      result = convert(pcm, input_rate, output_rate, 1, 1, chunk) |> samples()
      {peak, index} = result |> Enum.with_index() |> Enum.max_by(fn {value, _} -> abs(value) end)
      assert abs(peak) > 2_000
      assert abs(index - round(impulse_at * output_rate / input_rate)) <= 2
    end
  end

  test "reset discards old filter history and restores the original ratio" do
    ref = converter(44_100, 24_000, 1, 1, 441)
    input = tone(44_100, 441, [440])
    assert {:ok, first, count} = ResampleProbe.process(ref, input)
    assert :ok = ResampleProbe.adjust(ref, 500)
    assert {:ok, _, _} = ResampleProbe.process(ref, input)
    assert :ok = ResampleProbe.reset(ref)
    assert {:ok, ^first, ^count} = ResampleProbe.process(ref, input)
  end

  test "small drift corrections change sample counts without discontinuous audio" do
    totals =
      for ppm <- [-500, 500] do
        ref = converter(48_000, 24_000, 1, 1, 480)

        {outputs, counts} =
          Enum.map(0..999, fn index ->
            if index == 100, do: assert(:ok = ResampleProbe.adjust(ref, ppm))
            {:ok, pcm, frames} = ResampleProbe.process(ref, tone(48_000, 480, [440], index * 480))
            {pcm, frames}
          end)
          |> Enum.unzip()

        expected = 24_000 + 216_000 * (1 + ppm / 1_000_000)
        # Allow rounding and the one-block ramp to the new rate.
        assert abs(Enum.sum(counts) - expected) < 4
        {_, _, _, _, actual_ratio} = ResampleProbe.info(ref)
        assert_in_delta actual_ratio, 0.5 * (1 + ppm / 1_000_000), 1.0e-12
        data = outputs |> IO.iodata_to_binary() |> samples() |> Enum.drop(1_000)
        jumps = Enum.zip_with(data, tl(data), fn a, b -> abs(a - b) end)
        assert Enum.max(jumps) < 1_200
        IO.puts("RUBATO_DRIFT ppm=#{ppm} frames=#{Enum.sum(counts)}")
        Enum.sum(counts)
      end

    [slower, faster] = totals
    assert abs(faster - slower - 216) <= 2
  end

  test "silence remains silent and full-scale output saturates without wrapping" do
    silence = convert(:binary.copy(<<0, 0>>, 44_100), 44_100, 24_000, 1, 1, 441)
    assert silence == :binary.copy(<<0, 0>>, 24_000)
    # A full-scale step causes filter overshoot; conversion must saturate.
    step = :binary.copy(<<0, 0>>, 24_000) <> :binary.copy(<<255, 127>>, 24_000)
    output = convert(step, 48_000, 24_000, 1, 1, 480) |> samples()
    assert Enum.all?(Enum.slice(output, 12_050, 11_900), &(&1 == 32_767))
    assert Enum.min(Enum.slice(output, 12_010, 100)) > 30_000
  end

  test "invalid inputs do not mutate state and closed state is rejected" do
    for args <- [
          {0, 24_000, 1, 1, 441},
          {44_100, 200_000, 1, 1, 441},
          {44_100, 24_000, 3, 1, 441},
          {44_100, 24_000, 1, 1, 100_000}
        ] do
      assert_raise ArgumentError, fn -> apply(ResampleProbe, :new, Tuple.to_list(args)) end
    end

    ref = converter(44_100, 24_000, 1, 1, 441)
    before = ResampleProbe.info(ref)

    for input <- [<<>>, <<0>>, :binary.copy(<<0>>, 881), :binary.copy(<<0>>, 884), [0, 1]] do
      assert_raise ArgumentError, fn -> ResampleProbe.process(ref, input) end
    end

    assert_raise ArgumentError, fn -> ResampleProbe.adjust(ref, 1001) end
    assert_raise ArgumentError, fn -> ResampleProbe.process(make_ref(), <<>>) end
    assert ResampleProbe.info(ref) == before
    assert :ok = ResampleProbe.close(ref)
    assert :ok = ResampleProbe.close(ref)
    assert {:error, :closed} = ResampleProbe.process(ref, :binary.copy(<<0>>, 882))
    assert {:error, :closed} = ResampleProbe.reset(ref)
  end

  @tag timeout: 30_000
  test "independent streams and shared-resource close contention" do
    shared = converter(44_100, 24_000, 2, 1, 441)
    input = tone(44_100, 441, [440, 660])

    results =
      1..100
      |> Task.async_stream(
        fn i ->
          if rem(i, 10) == 0,
            do: ResampleProbe.close(shared),
            else: ResampleProbe.process(shared, input)
        end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, fn
             :ok -> true
             {:ok, pcm, frames} -> byte_size(pcm) == frames * 2
             {:error, reason} -> reason in [:busy, :closed]
           end)

    {wall, timings} =
      :timer.tc(fn ->
        1..8
        |> Task.async_stream(
          fn _ ->
            {:ok, ref} = ResampleProbe.new(44_100, 24_000, 2, 1, 441)

            results =
              for _ <- 1..1_000 do
                {us, {:ok, _, frames}} = :timer.tc(fn -> ResampleProbe.process(ref, input) end)
                assert frames in 1..242
                us
              end

            assert :ok = ResampleProbe.close(ref)
            results
          end,
          max_concurrency: 8,
          timeout: 20_000
        )
        |> Enum.flat_map(fn {:ok, times} -> times end)
        |> Enum.sort()
      end)

    IO.puts(
      "RUBATO_LOAD blocks=#{length(timings)} wall_s=#{wall / 1_000_000} p50_us=#{Enum.at(timings, 4_000)} p95_us=#{Enum.at(timings, 7_600)} p99_us=#{Enum.at(timings, 7_920)} max_us=#{List.last(timings)}"
    )
  end
end
