defmodule Parlora.Providers.Gemini.Audio do
  @moduledoc false
  import Bitwise
  alias Parlora.AudioConverter

  def new(%{codec: codec}) do
    rate = if codec == :pcmu, do: 8_000, else: 24_000

    %{
      codec: codec,
      input: AudioConverter.new(rate, 16_000, 1, 1),
      output: if(codec == :pcmu, do: AudioConverter.new(24_000, 8_000, 1, 1))
    }
  end

  def input(audio, bytes) do
    pcm = if audio.codec == :pcmu, do: decode(bytes), else: bytes
    {converted, converter} = AudioConverter.convert(audio.input, pcm)
    {converted, %{audio | input: converter}}
  end

  def output(%{output: nil} = audio, bytes), do: {bytes, audio}

  def output(audio, bytes) do
    {pcm, converter} = AudioConverter.convert(audio.output, bytes)
    {encode(pcm), %{audio | output: converter}}
  end

  def reset_output(%{output: nil} = audio), do: audio
  def reset_output(audio), do: %{audio | output: AudioConverter.reset(audio.output)}
  def reset_input(audio), do: %{audio | input: AudioConverter.reset(audio.input)}

  def close(audio) do
    AudioConverter.close(audio.input)
    if audio.output, do: AudioConverter.close(audio.output)
    :ok
  end

  # ITU G.711 mu-law: complement sign/exponent/mantissa and remove the 132 bias.
  def decode(bytes) do
    for <<encoded <- bytes>>, into: <<>> do
      code = bxor(encoded, 255)
      magnitude = ((((code &&& 15) <<< 3) + 132) <<< (code >>> 4 &&& 7)) - 132
      sample = if (code &&& 128) == 0, do: magnitude, else: -magnitude
      <<sample::little-signed-16>>
    end
  end

  def encode(pcm) do
    for <<sample::little-signed-16 <- pcm>>, into: <<>> do
      magnitude = min(abs(sample), 32_635) + 132
      exponent = exponent(magnitude, 7)
      mantissa = magnitude >>> (exponent + 3) &&& 15
      sign = if sample < 0, do: 128, else: 0
      <<bxor(sign ||| exponent <<< 4 ||| mantissa, 255)>>
    end
  end

  defp exponent(value, exponent) when exponent > 0 do
    if (value &&& 1 <<< (exponent + 7)) == 0,
      do: exponent(value, exponent - 1),
      else: exponent
  end

  defp exponent(_value, 0), do: 0
end
