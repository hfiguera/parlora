defmodule Parlora.PhonicAudioTest do
  use ExUnit.Case, async: true
  alias Parlora.Audio.G711
  alias Parlora.AudioFormat
  alias Parlora.Providers.Phonic.Audio

  test "phone audio crosses the PCM24 wire at the correct rate without fragment padding" do
    converter = Audio.new(AudioFormat.pcmu())
    on_exit(fn -> Audio.close(converter) end)

    source =
      for sample <- 0..7_999,
          into: <<>>,
          do:
            <<round(10_000 * :math.sin(2 * :math.pi() * 1000 * sample / 8000))::little-signed-16>>

    encoded = G711.encode(source)

    {parts, converter} =
      Enum.map_reduce(for(<<part::binary-size(37) <- encoded>>, do: part), converter, fn bytes,
                                                                                         state ->
        Audio.input(state, bytes)
      end)

    consumed = div(byte_size(encoded), 37) * 37

    {tail, converter} =
      Audio.input(converter, binary_part(encoded, consumed, byte_size(encoded) - consumed))

    pcm24 = IO.iodata_to_binary(parts) <> tail
    assert byte_size(pcm24) in 47_900..48_000

    {phone, converter} = Audio.output(converter, pcm24)
    assert byte_size(phone) in 7_800..8_000
    samples = for <<sample::little-signed-16 <- G711.decode(phone)>>, do: sample
    {minimum, maximum} = Enum.min_max(samples)
    assert maximum > 7_000
    assert minimum < -7_000
    assert Enum.all?(samples, &(&1 in -32_768..32_767))
    converter = converter |> Audio.reset(:input) |> Audio.reset(:output)
    {silence, converter} = Audio.input(converter, :binary.copy(<<255>>, 160))
    assert byte_size(silence) in 900..960
    assert silence == :binary.copy(<<0>>, byte_size(silence))
    {silence, _converter} = Audio.output(converter, silence)
    assert byte_size(silence) in 60..160
    assert silence == :binary.copy(<<255>>, byte_size(silence))
  end

  test "PCM path preserves bytes and does not allocate native resamplers" do
    converter = Audio.new(%AudioFormat{})
    assert converter == %{input: nil, output: nil}
    assert {<<1, 2, 3, 4>>, ^converter} = Audio.input(converter, <<1, 2, 3, 4>>)
    assert {<<1, 2, 3, 4>>, ^converter} = Audio.output(converter, <<1, 2, 3, 4>>)
    assert Audio.reset(converter, :input) == converter
    assert :ok = Audio.close(converter)
  end
end
