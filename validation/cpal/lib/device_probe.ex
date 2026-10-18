defmodule DeviceProbe do
  @moduledoc "Validation-only CPAL device boundary; PCM16LE interleaved buffers."
  use Rustler, otp_app: :parlora_cpal_probe, crate: :cpal_probe, mode: :release
  def devices(_host), do: :erlang.nif_error(:not_loaded)
  def open(_host, _input_id, _output_id, _capacity), do: :erlang.nif_error(:not_loaded)
  def open_test(_capacity), do: :erlang.nif_error(:not_loaded)
  def stats(_ref), do: :erlang.nif_error(:not_loaded)
  def read(_ref, _frames), do: :erlang.nif_error(:not_loaded)
  def write(_ref, _pcm), do: :erlang.nif_error(:not_loaded)
  def clear(_ref), do: :erlang.nif_error(:not_loaded)
  def close(_ref), do: :erlang.nif_error(:not_loaded)
end
