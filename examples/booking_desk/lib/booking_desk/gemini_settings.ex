defmodule BookingDesk.GeminiSettings do
  @moduledoc "Clinic vocabulary and foreground speech detection; application overrides remain available."

  def options do
    [
      realtime_input_config: [
        automatic_activity_detection: [
          start_of_speech_sensitivity: :low,
          end_of_speech_sensitivity: :low,
          prefix_padding_ms: 120
        ],
        interim_transcript_timestamp_enabled: true
      ],
      input_audio_transcription: [
        language_codes: ["en-US"],
        custom_vocabulary: ["Cedarwood", "Dr. Lee", "Dr. Patel"],
        mode: :verbatim
      ]
    ]
  end
end
