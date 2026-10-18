defmodule OpusProbe do
  @moduledoc "Validation-only direct libopus NIF. Not a production codec API."
  @on_load :load_nif

  def load_nif do
    path =
      case System.get_env("OPUS_PROBE_NIF") do
        nil -> :filename.join(:code.priv_dir(:parlora_opus_probe), ~c"opus_probe")
        path -> String.to_charlist(path)
      end

    :erlang.load_nif(path, 0)
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
