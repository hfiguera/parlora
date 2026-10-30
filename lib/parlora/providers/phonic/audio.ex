defmodule Parlora.Providers.Phonic.Audio do
  @moduledoc false
  alias Parlora.Audio.G711
  alias Parlora.AudioConverter

  def new(%{codec: :pcm}), do: %{input: nil, output: nil}

  def new(%{codec: :pcmu}) do
    %{
      input: AudioConverter.new(8_000, 24_000, 1, 1),
      output: AudioConverter.new(24_000, 8_000, 1, 1)
    }
  end

  def input(%{input: nil} = audio, bytes), do: {bytes, audio}

  def input(audio, bytes) do
    {pcm, converter} = AudioConverter.convert(audio.input, G711.decode(bytes))
    {pcm, %{audio | input: converter}}
  end

  def output(%{output: nil} = audio, bytes), do: {bytes, audio}

  def output(audio, bytes) do
    {pcm, converter} = AudioConverter.convert(audio.output, bytes)
    {G711.encode(pcm), %{audio | output: converter}}
  end

  def reset(audio, direction) do
    if converter = audio[direction],
      do: Map.put(audio, direction, AudioConverter.reset(converter)),
      else: audio
  end

  def close(nil), do: :ok

  def close(audio) do
    for converter <- [audio.input, audio.output],
        converter != nil,
        do: AudioConverter.close(converter)

    :ok
  end
end
