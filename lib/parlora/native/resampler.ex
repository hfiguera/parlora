defmodule Parlora.Native.Resampler do
  @moduledoc false
  if Application.compile_env(:parlora, :native_audio, true) do
    use Rustler, otp_app: :parlora, crate: :parlora_rubato, mode: :release
  end

  def new(_input_rate, _output_rate, _input_channels, _output_channels, _chunk_frames),
    do: :erlang.nif_error(:not_loaded)

  def info(_ref), do: :erlang.nif_error(:not_loaded)
  def process(_ref, _pcm), do: :erlang.nif_error(:not_loaded)
  def adjust(_ref, _ppm), do: :erlang.nif_error(:not_loaded)
  def reset(_ref), do: :erlang.nif_error(:not_loaded)
  def close(_ref), do: :erlang.nif_error(:not_loaded)
end
