defmodule BookingDesk.GrokSettingsTest do
  use ExUnit.Case, async: false
  alias Parlora.AudioFormat
  alias Parlora.Providers.Grok.Protocol

  setup do
    saved = System.get_env("XAI_API_KEY")
    provider = System.get_env("PARLORA_PROVIDER")
    System.put_env("XAI_API_KEY", "booking-test-key")
    System.put_env("PARLORA_PROVIDER", "phonic")

    on_exit(fn ->
      if saved, do: System.put_env("XAI_API_KEY", saved), else: System.delete_env("XAI_API_KEY")

      if provider,
        do: System.put_env("PARLORA_PROVIDER", provider),
        else: System.delete_env("PARLORA_PROVIDER")
    end)

    :ok
  end

  test "the booking profile uses normal pacing, clinic recognition and no automatic idle questions" do
    assert {Parlora.Providers.Grok, options} = BookingDesk.provider("grok")
    assert options[:voice] == BookingDesk.GrokSettings.voice()
    assert {:ok, %{setup: %{session: session}}} = Protocol.start(options, %AudioFormat{})
    assert session.audio.output.speed == 1.0
    assert session.audio.input.transcription.language_hint == "en"
    assert session.audio.input.transcription.keyterms == ["Cedarwood", "Dr. Lee", "Dr. Patel"]
    assert session.turn_detection == %{type: "server_vad", idle_timeout_ms: nil}
    assert session.replace == %{}
    assert session.reasoning.effort == "high"
  end

  test "application overrides replace individual booking defaults" do
    assert {Parlora.Providers.Grok, options} =
             BookingDesk.provider("grok",
               voice: "celeste",
               speed: 1.05,
               keyterms: ["Other clinic"],
               idle_timeout_ms: 20_000,
               replace: %{"Other clinic" => "Other Clinic"},
               reasoning_effort: :none
             )

    assert {:ok, %{setup: %{session: session}}} = Protocol.start(options, %AudioFormat{})
    assert session.voice == "celeste"
    assert session.audio.output.speed == 1.05
    assert session.audio.input.transcription.keyterms == ["Other clinic"]
    assert session.turn_detection.idle_timeout_ms == 20_000
    assert session.replace == %{"Other clinic" => "Other Clinic"}
    assert session.reasoning.effort == "none"
    assert session.audio.input.transcription.language_hint == "en"
  end

  test "Parlora's Grok defaults remain independent of the booking profile" do
    assert {:ok, %{setup: %{session: session}}} =
             Protocol.start([api_key: "test"], %AudioFormat{})

    assert session.audio.output.speed == 1.0
    assert session.audio.input.transcription == %{model: "grok-transcribe"}
    assert session.turn_detection == %{type: "server_vad", idle_timeout_ms: nil}
    refute Map.has_key?(session, :replace)
    assert BookingDesk.provider_options("openai") == []
    assert BookingDesk.provider_options("gemini") == BookingDesk.GeminiSettings.options()

    assert BookingDesk.provider_options("phonic") == [
             boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"],
             vad_threshold: 0.8,
             wait_for_speech_before_tool_call: true
           ]
  end
end
