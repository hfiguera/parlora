defmodule Parlora.PhonicDefaultsTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, Providers.Phonic}
  alias Parlora.Providers.Phonic.Protocol

  test "credentials alone select native conversation and the tested listening profile" do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, config} = Protocol.start([api_key: "test"], format)
      assert config.enable_assistant_backchannel
      assert config.assistant_backchannel_aggressiveness == 0.3
      assert config.audio_speed == 1.0
      assert config.vad_threshold == 0.7
      assert config.vad_min_speech_duration_ms == 120
      assert config.vad_min_silence_duration_ms == 600
      assert config.min_words_to_interrupt == 1
      assert config.background_noise == nil
      assert config.background_noise_level == 0
      refute Map.has_key?(config, :boosted_keywords)
      refute Map.has_key?(config, :pronunciation_dictionary)
      refute Map.has_key?(config, :api_key)
      assert [tool] = config.tools
      assert tool.require_speech_before_tool_call
      refute tool.wait_for_speech_before_tool_call
      assert tool.wait_for_response
      assert tool.tool_call_output_timeout_ms == 60_000
      assert tool.execution_mode == "async" and tool.forbid_speech_after_tool_call
      refute tool.allow_tool_chaining or tool.can_run_during_user_speech
    end
  end

  test "normal speed is explicit and app speed overrides change no other native settings" do
    assert Phonic.default_options()[:audio_speed] == 1.0

    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, baseline} = Protocol.start([api_key: "test"], format)
      assert {:ok, ^baseline} = Protocol.start([api_key: "test", audio_speed: 1.0], format)

      for speed <- [0.5, 1.05, 1.5] do
        assert {:ok, custom} = Protocol.start([api_key: "test", audio_speed: speed], format)
        assert custom == %{baseline | audio_speed: speed}
      end

      assert {:ok, ^baseline} = Protocol.start([api_key: "test"], format)
    end
  end

  test "explicit false, zero and nil overrides survive default resolution" do
    assert {:ok, config} =
             Protocol.start(
               [
                 api_key: "test",
                 enable_assistant_backchannel: false,
                 require_speech_before_tool_call: false,
                 wait_for_speech_before_tool_call: true,
                 wait_for_response: false,
                 audio_speed: 0.75,
                 vad_min_speech_duration_ms: 0,
                 vad_threshold: 0.42,
                 vad_min_silence_duration_ms: 0,
                 vad_prebuffer_duration_ms: 0,
                 background_noise: nil,
                 background_noise_level: 0,
                 no_input_poke_sec: nil,
                 tool_timeout_ms: 45_000
               ],
               %AudioFormat{}
             )

    refute config.enable_assistant_backchannel
    refute Map.has_key?(config, :assistant_backchannel_aggressiveness)
    assert config.audio_speed == 0.75
    assert config.vad_min_speech_duration_ms == 0
    assert config.vad_threshold == 0.42
    assert config.vad_min_silence_duration_ms == 0
    assert config.vad_prebuffer_duration_ms == 0
    assert config.background_noise == nil and config.background_noise_level == 0
    assert config.no_input_poke_sec == nil
    assert [tool] = config.tools
    refute tool.require_speech_before_tool_call or tool.wait_for_response
    assert tool.wait_for_speech_before_tool_call
    assert tool.tool_call_output_timeout_ms == 45_000
  end

  test "conditional backchannel defaults distinguish inherited and explicitly invalid values" do
    assert {:ok, config} =
             Protocol.start(
               [api_key: "test", assistant_backchannel_aggressiveness: 0],
               %AudioFormat{}
             )

    assert config.enable_assistant_backchannel and
             config.assistant_backchannel_aggressiveness == 0

    assert {:error,
            %{code: :invalid_argument, details: %{setting: :assistant_backchannel_aggressiveness}}} =
             Protocol.start(
               [
                 api_key: "test",
                 enable_assistant_backchannel: false,
                 assistant_backchannel_aggressiveness: 0.3
               ],
               %AudioFormat{}
             )
  end

  test "duplicate overrides are rejected before merging can erase them" do
    assert {:error, %{code: :invalid_argument}} =
             Protocol.start(
               [api_key: "test", wait_for_response: true, wait_for_response: false],
               %AudioFormat{}
             )
  end

  test "app-specific settings stay local to the configured session" do
    assert {:ok, custom} =
             Protocol.start(
               [api_key: "test", boosted_keywords: ["My Company"], instructions: "Be concise."],
               %AudioFormat{}
             )

    assert custom.boosted_keywords == ["My Company"]
    assert String.starts_with?(custom.system_prompt, "Be concise.")
    assert {:ok, baseline} = Protocol.start([api_key: "test"], %AudioFormat{})
    refute Map.has_key?(baseline, :boosted_keywords)
    assert String.starts_with?(baseline.system_prompt, "Keep replies brief.")
    refute Keyword.has_key?(Phonic.default_options(), :api_key)
    refute Keyword.has_key?(Phonic.default_options(), :boosted_keywords)
  end
end
