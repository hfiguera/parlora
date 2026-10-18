defmodule Parlora.Limits do
  @moduledoc "Finite per-session bounds. Audio capacities are bytes of the agreed pipeline format."
  alias Parlora.{AudioFormat, Error}

  @type t :: %__MODULE__{
          audio_queue_bytes: pos_integer(),
          provider_audio_queue_bytes: pos_integer(),
          provider_audio_max_age_ms: pos_integer(),
          max_frame_bytes: pos_integer(),
          tick_ms: pos_integer(),
          audio_backpressure_timeout_ms: pos_integer(),
          max_jobs: pos_integer(),
          max_pending_jobs: pos_integer(),
          max_pending_delegations: pos_integer(),
          max_records: pos_integer(),
          max_subscribers: pos_integer(),
          max_subscriber_queue: pos_integer(),
          max_transcripts: pos_integer(),
          startup_timeout_ms: pos_integer(),
          policy_timeout_ms: pos_integer(),
          cancellation_timeout_ms: pos_integer(),
          shutdown_timeout_ms: pos_integer(),
          job_timeout_ms: pos_integer()
        }
  defstruct audio_queue_bytes: 9_600,
            provider_audio_queue_bytes: 33_600,
            provider_audio_max_age_ms: 750,
            max_frame_bytes: 960,
            tick_ms: 10,
            audio_backpressure_timeout_ms: 500,
            max_jobs: 4,
            max_pending_jobs: 8,
            max_pending_delegations: 32,
            max_records: 4_096,
            max_subscribers: 32,
            max_subscriber_queue: 2_048,
            max_transcripts: 8_192,
            startup_timeout_ms: 15_000,
            policy_timeout_ms: 5_000,
            cancellation_timeout_ms: 2_000,
            shutdown_timeout_ms: 5_000,
            job_timeout_ms: 30_000

  @spec new(keyword(), AudioFormat.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(options \\ [], format \\ %AudioFormat{}) do
    defaults = Map.from_struct(%__MODULE__{})

    if AudioFormat.supported?(format) and Keyword.keyword?(options) and
         Enum.all?(options, fn {key, value} ->
           Map.has_key?(defaults, key) and is_integer(value) and value > 0
         end) do
      settings = [
        audio_queue_bytes: AudioFormat.bytes_for_ms(format, 200),
        provider_audio_queue_bytes: AudioFormat.bytes_for_ms(format, 700),
        max_frame_bytes: AudioFormat.bytes_for_ms(format, 20)
      ]

      validate(struct!(__MODULE__, Keyword.merge(settings, options)), format)
    else
      Error.tuple(:invalid_argument, "Limits must be known, positive integer settings")
    end
  end

  defp validate(limits, format) do
    alignment = AudioFormat.sample_bytes(format)

    if limits.max_frame_bytes >= AudioFormat.bytes_for_ms(format, 10) and
         limits.max_frame_bytes <= limits.audio_queue_bytes and
         limits.max_frame_bytes <= limits.provider_audio_queue_bytes and
         rem(limits.provider_audio_queue_bytes, alignment) == 0 and
         rem(limits.max_frame_bytes, alignment) == 0 do
      {:ok, limits}
    else
      Error.tuple(
        :invalid_argument,
        "Frame size must hold at least 10 ms and fit both audio budgets; frames and provider capacity must contain complete samples"
      )
    end
  end
end
