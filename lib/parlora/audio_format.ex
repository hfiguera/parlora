defmodule Parlora.AudioFormat do
  @moduledoc "Explicit pipeline encoding and byte timing for PCM16LE and G.711 μ-law."
  @type t :: %__MODULE__{
          codec: :pcm | :pcmu,
          sample_rate_hz: pos_integer(),
          channels: pos_integer(),
          sample_format: :s16le | nil
        }
  defstruct codec: :pcm, sample_rate_hz: 24_000, channels: 1, sample_format: :s16le

  @spec pcmu() :: t()
  def pcmu, do: %__MODULE__{codec: :pcmu, sample_rate_hz: 8_000, sample_format: nil}

  @spec supported?(term()) :: boolean()
  def supported?(format), do: format in [%__MODULE__{}, pcmu()]

  @spec sample_bytes(t()) :: pos_integer()
  def sample_bytes(%__MODULE__{codec: :pcm, sample_format: :s16le, channels: channels}),
    do: 2 * channels

  def sample_bytes(%__MODULE__{codec: :pcmu, channels: channels}), do: channels

  @spec duration_us(t(), non_neg_integer()) :: non_neg_integer()
  def duration_us(format, bytes),
    do: div(bytes * 1_000_000, format.sample_rate_hz * sample_bytes(format))

  @spec bytes_for_ms(t(), non_neg_integer()) :: non_neg_integer()
  def bytes_for_ms(format, ms),
    do: div(format.sample_rate_hz * ms, 1_000) * sample_bytes(format)

  @spec aligned?(term(), binary()) :: boolean()
  def aligned?(format, data),
    do: supported?(format) and rem(byte_size(data), sample_bytes(format)) == 0

  @spec silence(t(), non_neg_integer()) :: binary()
  def silence(format, ms) do
    byte = if format.codec == :pcmu, do: <<255>>, else: <<0>>
    :binary.copy(byte, bytes_for_ms(format, ms))
  end
end
