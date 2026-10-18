defmodule Parlora.TestSupport.AudioBenchmark.Signal do
  @moduledoc false

  # Continuous-phase chirp: unique progression, no artificial frame-boundary clicks.
  def pcm(ms) do
    slope = min(35, 1_750_000 / ms)

    for n <- 0..(ms * 24 - 1), into: <<>> do
      t = n / 24_000
      value = round(8_000 * :math.sin(2 * :math.pi() * (220 * t + slope * t * t)))
      <<value::signed-little-16>>
    end
  end

  def wav(pcm, rate \\ 24_000) do
    size = byte_size(pcm)

    <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      rate::little-32, rate * 2::little-32, 2::little-16, 16::little-16, "data", size::little-32,
      pcm::binary>>
  end
end
