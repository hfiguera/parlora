defmodule Parlora.GeminiAudioTest do
  use ExUnit.Case, async: true
  alias Parlora.AudioFormat
  alias Parlora.Providers.Gemini.Audio

  test "G.711 decode vectors and canonical round trip cover all codewords" do
    assert Audio.decode(<<255, 127, 0, 128, 254, 126>>) ==
             <<0::little-signed-16, 0::little-signed-16, -32_124::little-signed-16,
               32_124::little-signed-16, 8::little-signed-16, -8::little-signed-16>>

    for code <- 0..255 do
      assert Audio.encode(Audio.decode(<<code>>)) == <<if(code == 127, do: 255, else: code)>>
    end
  end

  for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
    @format format
    test "streaming #{@format.codec} converts to 16 kHz input and back from 24 kHz" do
      audio = Audio.new(@format)
      on_exit(fn -> Audio.close(audio) end)
      input = AudioFormat.silence(@format, 100)
      {converted, audio} = Audio.input(audio, input)
      assert byte_size(converted) in 3_000..3_200
      assert rem(byte_size(converted), 2) == 0
      output = :binary.copy(<<1000::little-signed-16>>, 2_400)
      {returned, audio} = Audio.output(audio, output)
      expected = AudioFormat.bytes_for_ms(@format, 100)
      # The stateful resampler retains its fractional first output sample.
      assert byte_size(returned) in (expected - 1)..expected
      reset = audio |> Audio.reset_input() |> Audio.reset_output()
      {silent, _audio} = Audio.input(reset, input)
      assert silent == converted
    end
  end
end
