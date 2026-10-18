defmodule Parlora.Native.Device do
  @moduledoc false
  if Application.compile_env(:parlora, :native_audio, true) do
    use Rustler, otp_app: :parlora, crate: :parlora_cpal, mode: :release
  end

  def devices(_host), do: :erlang.nif_error(:not_loaded)
  def open(_host, _input_id, _output_id, _capacity), do: :erlang.nif_error(:not_loaded)
  def open_test(_capacity), do: :erlang.nif_error(:not_loaded)
  def stats(_ref), do: :erlang.nif_error(:not_loaded)
  def read(_ref, _frames), do: :erlang.nif_error(:not_loaded)
  def write(_ref, _pcm, _epoch), do: :erlang.nif_error(:not_loaded)
  def clear(_ref, _epoch), do: :erlang.nif_error(:not_loaded)
  def close(_ref), do: :erlang.nif_error(:not_loaded)
end
