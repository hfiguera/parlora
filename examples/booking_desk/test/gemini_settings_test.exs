defmodule BookingDesk.GeminiSettingsTest do
  use ExUnit.Case, async: false
  alias Parlora.{AudioFormat, ContextUpdate}
  alias Parlora.Providers.Gemini.Protocol

  test "the booking profile tunes speech onset and recognition while retaining native interruption" do
    assert {:ok, %{setup: setup}} =
             Protocol.start(
               [api_key: "test"] ++ BookingDesk.provider_options("gemini"),
               %AudioFormat{}
             )

    detection = setup.realtimeInputConfig.automaticActivityDetection
    assert detection.startOfSpeechSensitivity == "START_SENSITIVITY_LOW"
    assert detection.endOfSpeechSensitivity == "END_SENSITIVITY_LOW"
    assert detection.prefixPaddingMs == 120
    assert detection.silenceDurationMs == 700
    refute detection.disabled
    assert setup.realtimeInputConfig.activityHandling == "START_OF_ACTIVITY_INTERRUPTS"
    assert setup.inputAudioTranscription.languageCodes == ["en-US"]
    assert setup.inputAudioTranscription.customVocabulary == ["Cedarwood", "Dr. Lee", "Dr. Patel"]
    assert setup.inputAudioTranscription.mode == "VERBATIM"
    assert Protocol.capabilities().context_update_kinds == [:speakable]

    assert {:error, _} =
             Protocol.validate_update(
               %ContextUpdate{
                 id: "unsupported",
                 kind: :instruction,
                 content: "Ignore consent",
                 provider_generation: 0
               },
               0
             )
  end

  test "applications override individual nested fields while retaining clinic recognition and tuning" do
    options =
      BookingDesk.provider_options("gemini",
        realtime_input_config: [
          automatic_activity_detection: [start_of_speech_sensitivity: :high]
        ],
        input_audio_transcription: [language_codes: ["es-US"]]
      )

    assert {:ok, %{setup: setup}} = Protocol.start([api_key: "test"] ++ options, %AudioFormat{})

    assert setup.realtimeInputConfig.automaticActivityDetection.startOfSpeechSensitivity ==
             "START_SENSITIVITY_HIGH"

    assert setup.inputAudioTranscription == %{
             languageCodes: ["es-US"],
             customVocabulary: ["Cedarwood", "Dr. Lee", "Dr. Patel"],
             mode: "VERBATIM"
           }

    assert setup.realtimeInputConfig.automaticActivityDetection.endOfSpeechSensitivity ==
             "END_SENSITIVITY_LOW"

    assert setup.realtimeInputConfig.automaticActivityDetection.prefixPaddingMs == 120
    assert setup.realtimeInputConfig.interimTranscriptTimestampEnabled
    assert {:ok, %{setup: defaults}} = Protocol.start([api_key: "test"], %AudioFormat{})

    assert defaults.realtimeInputConfig == %{
             automaticActivityDetection: %{disabled: false, silenceDurationMs: 700},
             activityHandling: "START_OF_ACTIVITY_INTERRUPTS"
           }

    assert defaults.inputAudioTranscription == %{mode: "VERBATIM"}
    assert BookingDesk.provider_options("openai") == []
  end

  test "the booking profile can use manual detection without inheriting incompatible tuning" do
    options =
      BookingDesk.provider_options("gemini",
        realtime_input_config: [automatic_activity_detection: [disabled: true]],
        input_audio_transcription: [custom_vocabulary: []]
      )

    assert {:ok, %{setup: setup, manual_activity?: true}} =
             Protocol.start([api_key: "test"] ++ options, %AudioFormat{})

    assert setup.realtimeInputConfig.automaticActivityDetection == %{disabled: true}
    assert setup.inputAudioTranscription.customVocabulary == []
    assert setup.inputAudioTranscription.languageCodes == ["en-US"]
  end

  test "the provider tuple preserves nested overrides, explicit credentials and voice" do
    original = System.get_env("GEMINI_API_KEY")
    System.put_env("GEMINI_API_KEY", "environment-test-key")

    on_exit(fn ->
      if original,
        do: System.put_env("GEMINI_API_KEY", original),
        else: System.delete_env("GEMINI_API_KEY")
    end)

    assert {Parlora.Providers.Gemini, options} =
             BookingDesk.provider("gemini",
               api_key: "session-test-key",
               voice: "Puck",
               realtime_input_config: [automatic_activity_detection: [prefix_padding_ms: 200]]
             )

    assert options[:api_key] == "session-test-key"
    assert options[:voice] == "Puck"
    assert {:ok, %{setup: setup}} = Protocol.start(options, %AudioFormat{})
    assert setup.realtimeInputConfig.automaticActivityDetection.prefixPaddingMs == 200

    assert setup.realtimeInputConfig.automaticActivityDetection.startOfSpeechSensitivity ==
             "START_SENSITIVITY_LOW"

    assert setup.realtimeInputConfig.interimTranscriptTimestampEnabled
  end

  test "recording metadata serializes nested native settings without credentials" do
    encoded =
      BookingDesk.RunReport.provider_options(
        [api_key: "private-test"] ++ BookingDesk.GeminiSettings.options()
      )
      |> JSON.encode!()

    refute encoded =~ "private-test"
    report = JSON.decode!(encoded)

    assert report["realtime_input_config"]["automatic_activity_detection"][
             "start_of_speech_sensitivity"
           ] == "low"

    assert report["input_audio_transcription"]["language_codes"] == ["en-US"]
  end
end
