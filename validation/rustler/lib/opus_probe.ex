defmodule OpusProbe do
  @moduledoc "Validation-only Rustler binding implementing the shared codec test API."
  use Rustler, otp_app: :parlora_rustler_probe, crate: :opus_rustler_probe, mode: :release

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
  def inject_panic, do: :erlang.nif_error(:not_loaded)
  def inject_resource_panic(_ref), do: :erlang.nif_error(:not_loaded)
  def inject_abort, do: :erlang.nif_error(:not_loaded)
end
