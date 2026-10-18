defmodule Parlora.Native.Opus do
  @moduledoc false
  if Application.compile_env(:parlora, :native_opus, true) do
    use Rustler, otp_app: :parlora, crate: :parlora_opus, mode: :release
  end

  def version, do: :erlang.nif_error(:not_loaded)
  def new(_kind, _rate, _channels, _application), do: :erlang.nif_error(:not_loaded)

  def configure(_ref, _bitrate, _complexity, _fec, _loss, _dtx, _bandwidth),
    do: :erlang.nif_error(:not_loaded)

  def settings(_ref), do: :erlang.nif_error(:not_loaded)
  def encode(_ref, _pcm, _samples), do: :erlang.nif_error(:not_loaded)
  def decode(_ref, _packet_or_nil, _samples, _fec), do: :erlang.nif_error(:not_loaded)
  def packet_info(_packet, _rate), do: :erlang.nif_error(:not_loaded)
  def reset(_ref), do: :erlang.nif_error(:not_loaded)
  def close(_ref), do: :erlang.nif_error(:not_loaded)
end
