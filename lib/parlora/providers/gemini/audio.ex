defmodule Parlora.Providers.Gemini.Audio do
  @moduledoc false
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

  defdelegate decode(bytes), to: Parlora.Audio.G711
  defdelegate encode(pcm), to: Parlora.Audio.G711
end
