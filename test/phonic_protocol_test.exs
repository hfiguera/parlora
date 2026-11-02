defmodule Parlora.PhonicProtocolTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextUpdate}
  alias Parlora.Providers.Phonic.{Calls, Protocol}

  test "native conversational controls reach the config without changing execution authority" do
    options = [
      enable_assistant_backchannel: true,
      assistant_backchannel_aggressiveness: 0.3,
      audio_speed: 1.1,
      background_noise: "office",
      background_noise_level: 0.1,
      vad_prebuffer_duration_ms: 400,
      vad_min_speech_duration_ms: 60,
      vad_min_silence_duration_ms: 600,
      vad_threshold: 0.4,
      min_words_to_interrupt: 2,
      boosted_keywords: ["Cedarwood", "Dr. Lee"],
      pronunciation_dictionary: [%{word: "Cedarwood", pronunciation: "SEE-der-wood"}],
      intelligence_level: "high",
      default_language: "en",
      additional_languages: ["es", "fr"],
      multilingual_mode: "auto",
      generate_no_input_poke_text: false,
      no_input_poke_sec: 15,
      no_input_poke_text: "Are you still there?",
      no_input_end_conversation_sec: 300
    ]

    assert {:ok, config} =
             Protocol.start(
               [
                 api_key: "test",
                 require_speech_before_tool_call: true,
                 wait_for_speech_before_tool_call: false
               ] ++ options,
               %AudioFormat{}
             )

    assert Map.take(config, Keyword.keys(options)) == Map.new(options)
    assert [tool] = config.tools
    assert tool.require_speech_before_tool_call
    refute tool.wait_for_speech_before_tool_call
    refute tool.wait_for_response or tool.allow_tool_chaining or tool.can_run_during_user_speech
    assert tool.execution_mode == "async" and tool.forbid_speech_after_tool_call
    assert tool.tool_schema.function.name == Protocol.function()
    assert tool.tool_schema.function.strict
    assert config.model == "phonic-1" and config.input_format == "pcm_24000"
  end

  test "invalid native settings and misspellings return errors instead of being silently ignored" do
    for {key, value} <- [
          enable_assistant_backchannel: "true",
          assistant_backchannel_aggressiveness: 0.5,
          audio_speed: 1.51,
          background_noise: "cafe",
          background_noise_level: -0.1,
          vad_prebuffer_duration_ms: 2001,
          vad_min_speech_duration_ms: 1501,
          vad_min_silence_duration_ms: 1.5,
          vad_threshold: 0.1,
          min_words_to_interrupt: 0,
          boosted_keywords: [String.duplicate("a", 51)],
          boosted_keywords: [String.duplicate("e\u0301", 26)],
          boosted_keywords: ["same", "same"],
          boosted_keywords: ["valid" | :invalid],
          pronunciation_dictionary: [%{word: "x", pronunciation: "x", other: "x"}],
          pronunciation_dictionary: [%{word: String.duplicate("a", 31), pronunciation: "x"}],
          pronunciation_dictionary: [%{word: "a", pronunciation: String.duplicate("x", 51)}],
          pronunciation_dictionary: [
            %{word: "a", pronunciation: "x"},
            %{"word" => "a", "pronunciation" => "y"}
          ],
          intelligence_level: :high,
          default_language: "English",
          additional_languages: ["en"],
          multilingual_mode: "guess",
          generate_no_input_poke_text: :yes,
          no_input_poke_sec: 121,
          no_input_poke_text: "",
          no_input_end_conversation_sec: 601,
          require_speech_before_tool_call: :yes,
          wait_for_speech_before_tool_call: 1,
          wait_for_response: :yes,
          forbid_speech_after_tool_call: :yes,
          enable_assistant_backchannels: true
        ] do
      assert {:error, %{code: :invalid_argument, details: %{setting: ^key}}} =
               Protocol.start([{:api_key, "test"}, {key, value}], %AudioFormat{})
    end

    for options <- [
          nil,
          %{},
          [:bad],
          [{:api_key, "test"}, {:audio_speed, 1}, {:audio_speed, 1.1}]
        ] do
      assert {:error, %{code: :invalid_argument}} = Protocol.start(options, %AudioFormat{})
    end

    assert {:error, %{code: :invalid_argument, details: %{setting: :additional_languages}}} =
             Protocol.start(
               [
                 api_key: "test",
                 multilingual_mode: "auto",
                 additional_languages: ["es", "fr", "de"]
               ],
               %AudioFormat{}
             )
  end

  test "native boundaries, nullable settings and dictionary JSON keys are supported" do
    for options <- [
          [audio_speed: 0.5, vad_prebuffer_duration_ms: 0, vad_threshold: 0.2],
          [audio_speed: 1.5, vad_min_silence_duration_ms: 1500, vad_threshold: 0.8],
          [enable_assistant_backchannel: true, assistant_backchannel_aggressiveness: 0],
          [enable_assistant_backchannel: true, assistant_backchannel_aggressiveness: 1],
          [background_noise: nil, no_input_poke_sec: nil],
          [boosted_keywords: [String.duplicate("雪", 50)]],
          [require_speech_before_tool_call: false, wait_for_speech_before_tool_call: true]
        ] do
      assert {:ok, _} = Protocol.start([api_key: "test"] ++ options, %AudioFormat{})
    end

    assert {:ok, config} =
             Protocol.start(
               [
                 api_key: "test",
                 pronunciation_dictionary: [%{"word" => "Lee", "pronunciation" => "lee"}]
               ],
               %AudioFormat{}
             )

    assert config.pronunciation_dictionary == [%{word: "Lee", pronunciation: "lee"}]
  end

  test "response ownership and tool schema cannot be overridden by native configuration" do
    for {key, value} <- [
          execution_mode: "sync",
          forbid_speech_after_tool_call: false,
          allow_tool_chaining: true
        ] do
      assert {:error, %{code: :unsupported, details: %{setting: ^key}}} =
               Protocol.start([{:api_key, "test"}, {key, value}], %AudioFormat{})
    end

    for key <- [
          :tools,
          :system_prompt,
          :input_format,
          :output_format,
          :push_to_talk,
          :additional_params
        ] do
      assert {:error, %{code: :invalid_argument}} =
               Protocol.start([{:api_key, "test"}, {key, "override"}], %AudioFormat{})
    end
  end

  test "native busy mode enables one provider-owned async result response" do
    assert {:ok, config} =
             Protocol.start([api_key: "test", wait_for_response: true], %AudioFormat{})

    assert [tool] = config.tools
    assert tool.wait_for_response and tool.forbid_speech_after_tool_call
    assert tool.execution_mode == "async"
    refute tool.allow_tool_chaining
    assert tool.tool_schema.function.strict

    assert {:ok, config} =
             Protocol.start(
               [api_key: "test", wait_for_response: true, forbid_speech_after_tool_call: false],
               %AudioFormat{}
             )

    refute hd(config.tools).forbid_speech_after_tool_call
  end

  test "configuration pins the model and codecs with strict asynchronous client delegation" do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, config} = Protocol.start([api_key: "test"], format)
      assert config.model == "phonic-1"
      assert config.input_format == "pcm_24000" and config.output_format == "pcm_24000"
      refute config.push_to_talk
      refute config.stream_ahead_of_real_time
      refute Map.has_key?(config, :data_retention_policy)
      refute Map.has_key?(config, :enable_assistant_backchannel)
      refute Map.has_key?(config, :audio_speed)
      refute Map.has_key?(config, :vad_min_silence_duration_ms)
      assert [tool] = config.tools
      assert tool.execution_mode == "async" and tool.wait_for_response == false
      refute tool.allow_tool_chaining
      assert tool.forbid_speech_after_tool_call
      assert tool.tool_schema.function.strict
      assert tool.tool_schema.function.name == Protocol.function()
      refute tool.can_run_during_user_speech
    end

    assert Protocol.path() == "/v1/sts/ws"
    caps = Protocol.capabilities()
    assert caps.full_duplex?
    assert caps.input_mute?
    assert caps.context_update_kinds == [:quiet, :speakable, :instruction]
    refute caps.usage?
    refute caps.context_acknowledgment?
  end

  test "retention and early delegation require explicit selection without a silent fallback" do
    assert {:ok, config} =
             Protocol.start(
               [api_key: "test", zero_data_retention: true, early_delegation: true],
               %AudioFormat{}
             )

    assert config.data_retention_policy == %{zero_data_retention: true}
    assert hd(config.tools).can_run_during_user_speech

    for options <- [
          [],
          [api_key: ""],
          [api_key: "test", voice: ""],
          [api_key: "test", tool_timeout_ms: 180_001],
          [api_key: "test", tool_timeout_ms: 999],
          [api_key: "test", acknowledgment_timeout_ms: 0],
          [api_key: "test", response_timeout_ms: :infinity],
          [api_key: "test", zero_data_retention: "true"]
        ] do
      assert {:error, %{code: :invalid_argument}} = Protocol.start(options, %AudioFormat{})
    end

    assert {:error, %{code: :unsupported}} =
             Protocol.start([api_key: "test", model: "phonic-latest"], %AudioFormat{})

    assert {:error, %{code: :unsupported}} =
             Protocol.start([api_key: "test", history: [%{}]], %AudioFormat{})

    assert {:error, %{code: :unsupported}} =
             Protocol.start([api_key: "test"], %AudioFormat{sample_rate_hz: 44_100})
  end

  test "context validates generation, kind, identity and JSON-encoded tool output bounds" do
    update = %ContextUpdate{
      id: "context",
      kind: :speakable,
      provider_generation: 2,
      content: "Verified fact"
    }

    assert :ok = Protocol.validate(update, 2)
    assert {:error, %{code: :invalid_argument}} = Protocol.validate(update, 1)
    assert {:error, %{code: :unsupported}} = Protocol.validate(%{update | kind: :other}, 2)
    assert {:error, %{code: :invalid_argument}} = Protocol.validate(%{update | id: ""}, 2)

    assert {:error, %{code: :invalid_argument}} =
             Protocol.validate(%{update | content: String.duplicate("a", 16_001)}, 2)

    assert {:error, %{code: :unsupported}} =
             Protocol.validate(%{update | kind: :quiet, delegation_id: "call"}, 2)

    assert :ok = Protocol.valid_output?(%{result: "雪", nested: [nil, true]})
    assert {:error, %{code: :invalid_argument}} = Protocol.valid_output?(%{result: self()})

    assert {:error, %{code: :invalid_argument}} =
             Protocol.valid_output?(%{result: String.duplicate("\"", 8_000)})
  end

  test "tool identities remain bounded and conflicting IDs never execute twice" do
    call = call("one", "order 123")
    assert {:new, %{"request" => "order 123"}, calls} = Calls.admit(Calls.new(1), call)
    assert {:duplicate, ^calls} = Calls.admit(calls, call)
    assert {:error, %{code: :invalid_argument}} = Calls.admit(calls, call("one", "order 124"))
    assert {:error, %{code: :backpressure}} = Calls.admit(calls, call("two", "order 124"))

    assert {:error, _} =
             Calls.admit(calls, %{
               call
               | "parameters" => %{"request" => "order 123", "extra" => true}
             })

    assert {:error, _} = Calls.admit(calls, %{call | "tool_name" => "execute_anything"})
  end

  test "clarification completes a call once and later results become fresh context" do
    {:new, _args, calls} = Calls.admit(Calls.new(4), call("clarify", "order"))

    assert {:ok, %{type: "tool_call_output", tool_call_id: "clarify"}, calls} =
             Calls.context(calls, "clarify", "Which order?")

    assert {:ok, %{type: "add_system_message"}, ^calls} =
             Calls.context(calls, "clarify", "Current verified result")

    assert {:error, _} = Calls.context(calls, "missing", "Unknown result")
  end

  test "expired calls accept current context while cancelled and superseded calls reject late results" do
    {:new, _, calls} = Calls.admit(Calls.new(4), call("call", "order"))
    assert {:changed, expired} = Calls.expire(calls, "call")

    assert {:ok, %{type: "add_system_message"}, ^expired} =
             Calls.context(expired, "call", "Late verified result")

    assert {:expired, ^expired} = Calls.complete(expired, "call", %{status: :associated})
    assert {:changed, cancelled} = Calls.cancel(calls, "call")
    assert {:error, _} = Calls.context(cancelled, "call", "Obsolete")
    assert {:ok, _, superseded} = Calls.complete(calls, "call", %{status: :superseded})
    assert {:duplicate, ^superseded} = Calls.complete(superseded, "call", %{status: :superseded})
    assert {:error, _} = Calls.context(superseded, "call", "Obsolete")
  end

  defp call(id, request),
    do: %{
      "tool_call_id" => id,
      "tool_name" => Protocol.function(),
      "parameters" => %{"request" => request}
    }
end
