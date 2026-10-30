defmodule Parlora.Audio.G711 do
  @moduledoc false
  import Bitwise

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
