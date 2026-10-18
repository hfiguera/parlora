defmodule Parlora.AudioFrame do
  @moduledoc "An ordered audio fragment. Locally derived timestamps are explicitly labeled."
  alias Parlora.{AudioFormat, Error, Limits}

  @type clock :: :local_monotonic | :provider | :unknown
  @type t :: %__MODULE__{
          data: binary(),
          format: AudioFormat.t(),
          stream_id: String.t(),
          sequence: non_neg_integer(),
          duration_us: non_neg_integer(),
          timestamp_us: integer() | nil,
          generation: non_neg_integer(),
          clock: clock(),
          discontinuity: boolean(),
          playback_epoch: non_neg_integer() | nil
        }
  defstruct [
    :data,
    :format,
    :stream_id,
    :sequence,
    :duration_us,
    :timestamp_us,
    generation: 0,
    clock: :unknown,
    discontinuity: false,
    playback_epoch: nil
  ]

  @spec pcm(binary(), String.t(), non_neg_integer(), keyword()) :: t()
  def pcm(data, stream_id, sequence, options \\ []) do
    new(data, Keyword.get(options, :format, %AudioFormat{}), stream_id, sequence, options)
  end

  @spec new(binary(), AudioFormat.t(), String.t(), non_neg_integer(), keyword()) :: t()
  def new(data, format, stream_id, sequence, options \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [
          data: data,
          format: format,
          stream_id: stream_id,
          sequence: sequence,
          duration_us: AudioFormat.duration_us(format, byte_size(data))
        ],
        options
      )
    )
  end

  @spec validate(term(), AudioFormat.t(), Limits.t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{data: data, format: format} = frame, format, limits)
      when is_binary(data) and byte_size(data) > 0 do
    if valid_audio?(frame, limits) and valid_metadata?(frame) do
      :ok
    else
      Error.tuple(:invalid_argument, "Malformed or oversized audio frame")
    end
  end

  def validate(_frame, _format, _limits),
    do: Error.tuple(:invalid_argument, "Unsupported audio frame or format")

  defp valid_audio?(frame, limits) do
    byte_size(frame.data) <= limits.max_frame_bytes and
      AudioFormat.aligned?(frame.format, frame.data) and
      frame.duration_us == AudioFormat.duration_us(frame.format, byte_size(frame.data))
  end

  defp valid_metadata?(frame) do
    is_integer(frame.sequence) and frame.sequence >= 0 and
      is_binary(frame.stream_id) and byte_size(frame.stream_id) > 0 and
      is_integer(frame.generation) and frame.generation >= 0 and valid_clock?(frame)
  end

  defp valid_clock?(frame) do
    frame.clock in [:local_monotonic, :provider, :unknown] and is_boolean(frame.discontinuity) and
      (frame.timestamp_us == nil or is_integer(frame.timestamp_us))
  end
end
