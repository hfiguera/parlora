defmodule ResampleProbe do
  @moduledoc "Validation-only stateful PCM16LE resampler; channels are interleaved."
  use Rustler, otp_app: :parlora_rubato_probe, crate: :rubato_probe, mode: :release

  def new(_input_rate, _output_rate, _input_channels, _output_channels, _chunk_frames),
    do: :erlang.nif_error(:not_loaded)

  def info(_ref), do: :erlang.nif_error(:not_loaded)
  def process(_ref, _pcm), do: :erlang.nif_error(:not_loaded)
  def adjust(_ref, _ppm), do: :erlang.nif_error(:not_loaded)
  def reset(_ref), do: :erlang.nif_error(:not_loaded)
  def close(_ref), do: :erlang.nif_error(:not_loaded)
end
