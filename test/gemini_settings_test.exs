defmodule Parlora.GeminiSettingsTest do
  use ExUnit.Case, async: true
  alias Parlora.AudioFormat
  alias Parlora.Providers.Gemini.Protocol

  test "native speech detection and transcription settings reach both wire formats" do
    options = [
      api_key: "test",
      realtime_input_config: [
        automatic_activity_detection: [
          start_of_speech_sensitivity: :low,
          end_of_speech_sensitivity: :low,
          prefix_padding_ms: 120,
          silence_duration_ms: 700
        ],
        activity_handling: :start_of_activity_interrupts,
        turn_coverage: :only_activity,
        interim_transcript_timestamp_enabled: true
      ],
      input_audio_transcription: [
        language_codes: ["en-US"],
        custom_vocabulary: ["Dr. Lee"],
        mode: :verbatim
      ]
    ]

    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, %{setup: setup, manual_activity?: false}} = Protocol.start(options, format)

      assert setup.realtimeInputConfig == %{
               automaticActivityDetection: %{
                 disabled: false,
                 startOfSpeechSensitivity: "START_SENSITIVITY_LOW",
                 endOfSpeechSensitivity: "END_SENSITIVITY_LOW",
                 prefixPaddingMs: 120,
                 silenceDurationMs: 700
               },
               activityHandling: "START_OF_ACTIVITY_INTERRUPTS",
               turnCoverage: "TURN_INCLUDES_ONLY_ACTIVITY",
               interimTranscriptTimestampEnabled: true
             }

      assert setup.inputAudioTranscription == %{
               languageCodes: ["en-US"],
               customVocabulary: ["Dr. Lee"],
               mode: "VERBATIM"
             }

      assert setup.outputAudioTranscription == %{}
    end
  end

  test "manual turns are explicit and cannot silently combine incompatible automatic controls" do
    assert {:ok, %{manual_activity?: true, setup: setup}} =
             Protocol.start(
               [
                 api_key: "test",
                 realtime_input_config: [automatic_activity_detection: [disabled: true]]
               ],
               %AudioFormat{}
             )

    assert setup.realtimeInputConfig.automaticActivityDetection == %{disabled: true}

    assert {:error, _} =
             Protocol.start(
               [
                 api_key: "test",
                 realtime_input_config: [
                   automatic_activity_detection: [disabled: true, silence_duration_ms: 700]
                 ]
               ],
               %AudioFormat{}
             )
  end

  test "malformed, misspelled and endpoint-unsupported options fail before connecting" do
    for bad <- [nil, %{}, [:bad], [{:api_key, "test"} | :bad]] do
      assert {:error, %{code: :invalid_argument}} = Protocol.start(bad, %AudioFormat{})
    end

    for opts <- [
          [invented: true],
          [api_key: "duplicate"],
          [realtime_input_config: nil],
          [realtime_input_config: %{turn_coverage: :only_activity}],
          [
            realtime_input_config: [
              automatic_activity_detection: [start_of_speech_sensitivity: "LOW"]
            ]
          ],
          [realtime_input_config: [automatic_activity_detection: [prefix_padding_ms: -1]]],
          [realtime_input_config: [automatic_activity_detection: [silence_duration_ms: 10_001]]],
          [realtime_input_config: [automatic_activity_detection: [disabled: nil]]],
          [realtime_input_config: [activity_handling: :ignore]],
          [realtime_input_config: [turn_coverage: :only_activity, turn_coverage: :all_input]],
          [input_audio_transcription: [language_codes: ["en_US"]]],
          [input_audio_transcription: [language_codes: ["en-US", "en-US"]]],
          [input_audio_transcription: [custom_vocabulary: [<<255>>]]],
          [input_audio_transcription: [custom_vocabulary: ["Lee" | :bad]]],
          [input_audio_transcription: [custom_vocabulary: List.duplicate("Lee", 257)]],
          [input_audio_transcription: [word_timestamp: true]],
          [input_audio_transcription: [diarization: true]],
          [input_audio_transcription: [mode: :invented]],
          [instruction_updates: true],
          [proactivity: false]
        ] do
      assert {:error, %{code: :invalid_argument}} =
               Protocol.start([api_key: "test"] ++ opts, %AudioFormat{})
    end
  end

  test "captions preserve offsets and metadata without authorizing or rewriting caller words" do
    assert [{:transcript, caption}, {:caller_speech, activity}] =
             Protocol.events(%{
               "serverContent" => %{
                 "inputTranscription" => %{
                   "text" => "Yes, if it is free",
                   "startOffset" => "12.123456789s",
                   "endOffset" => "12.9s",
                   "languageCode" => "en-US",
                   "speakerLabel" => "spk_1",
                   "finished" => true
                 }
               },
               "voiceActivity" => %{"type" => "ACTIVITY_END", "audioOffset" => "12.9s"}
             })

    assert caption.delta == "Yes, if it is free"
    assert caption.speaker == :user
    assert_in_delta caption.start_ms, 12_123.456789, 0.000001
    assert caption.end_ms == 12_900
    assert caption.timing == :provider_audio_stream
    assert caption.language_code == "en-US"
    assert caption.speaker_label == "spk_1"
    assert caption.finished
    assert activity == %{state: :finished, offset_ms: 12_900}

    for {first, last} <- [{"1s", "0s"}, {"invalid", "2s"}, {"-1s", "2s"}, {nil, "2s"}, {"1s", 2}] do
      assert [{:transcript, invalid}] =
               Protocol.events(%{
                 "serverContent" => %{
                   "inputTranscription" => %{
                     "text" => "Yep",
                     "startOffset" => first,
                     "endOffset" => last
                   }
                 }
               })

      assert invalid.start_ms == nil and invalid.end_ms == nil
      assert invalid.timing == :unavailable
    end
  end
end
