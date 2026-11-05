defmodule BookingDesk.PhonicSettingsTest do
  use ExUnit.Case, async: false

  alias Parlora.AudioFormat
  alias Parlora.Providers.Phonic.Protocol

  defmodule StartupChannel do
    def start_link(_init, opts) do
      send(Keyword.fetch!(opts, :owner), {:channel_starting, self()})

      receive do
        :finish_test -> {:error, :test_finished}
      end
    end
  end

  setup do
    variables = [
      "PARLORA_PROVIDER",
      "PHONIC_API_KEY",
      "OPENAI_API_KEY",
      "GEMINI_API_KEY",
      "XAI_API_KEY"
    ]

    saved = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {variable, value} <- saved do
        if value, do: System.put_env(variable, value), else: System.delete_env(variable)
      end
    end)

    System.put_env("PARLORA_PROVIDER", "openai")

    for variable <- tl(variables), do: System.put_env(variable, "booking-test-key")
    :ok
  end

  test "selecting Phonic applies the booking profile without an opt-in or matching environment" do
    assert {Parlora.Providers.Phonic, options} = BookingDesk.provider("phonic")

    assert Keyword.drop(options, [:api_key]) ==
             [boosted_keywords: ["Cedarwood", "Dr. Lee", "Dr. Patel"]]

    assert {:ok, config} = Protocol.start(options, %AudioFormat{})

    assert config.model == "phonic-1"
    assert config.voice_id == "sabrina"
    assert config.enable_assistant_backchannel
    assert config.assistant_backchannel_aggressiveness == 0.3
    assert config.audio_speed == 1.0
    assert config.vad_threshold == 0.7
    assert config.vad_min_speech_duration_ms == 120
    assert config.vad_min_silence_duration_ms == 600
    assert config.min_words_to_interrupt == 1
    assert config.boosted_keywords == ["Cedarwood", "Dr. Lee", "Dr. Patel"]

    assert [tool] = config.tools
    assert tool.require_speech_before_tool_call
    refute tool.wait_for_speech_before_tool_call
    assert tool.wait_for_response
    assert tool.tool_call_output_timeout_ms == 60_000
    assert tool.execution_mode == "async"
    assert tool.forbid_speech_after_tool_call
    refute tool.allow_tool_chaining
    refute tool.can_run_during_user_speech
    assert tool.tool_schema.function.strict
    assert tool.tool_schema.function.name == "delegate_to_backend"
  end

  test "speech detection can be tuned without requiring multiple words to interrupt" do
    {_, options} = BookingDesk.provider("phonic", vad_threshold: 0.55)
    assert {:ok, config} = Protocol.start(options, %AudioFormat{})
    assert config.vad_threshold == 0.55
    assert config.vad_min_speech_duration_ms == 120
    assert config.min_words_to_interrupt == 1
    assert config.enable_assistant_backchannel
    assert config.assistant_backchannel_aggressiveness == 0.3
    assert hd(config.tools).wait_for_response
    assert hd(config.tools).require_speech_before_tool_call
  end

  test "other booking providers retain their existing options even when the environment is Phonic" do
    System.put_env("PARLORA_PROVIDER", "phonic")

    for {name, module, expected} <- [
          {"openai", Parlora.Providers.OpenAI, %{api_key: "booking-test-key"}},
          {"gemini", Parlora.Providers.Gemini, %{api_key: "booking-test-key", voice: "Sulafat"}},
          {"grok", Parlora.Providers.Grok, %{api_key: "booking-test-key", voice: "ara"}}
        ] do
      assert {^module, options} = BookingDesk.provider(name)
      assert Map.new(options) == expected
    end
  end

  test "explicit provider options override the profile without discarding its other settings" do
    {_, options} =
      BookingDesk.provider("phonic",
        audio_speed: 0.95,
        wait_for_response: false,
        voice: "sabrina"
      )

    assert {:ok, config} = Protocol.start(options, %AudioFormat{})
    assert config.audio_speed == 0.95
    assert config.enable_assistant_backchannel
    assert config.vad_min_silence_duration_ms == 600
    assert [tool] = config.tools
    refute tool.wait_for_response
    assert tool.require_speech_before_tool_call
    assert tool.tool_call_output_timeout_ms == 60_000
  end

  test "explicit options select manual responses without duplicating library listening defaults" do
    assert {Parlora.Providers.Phonic, options} =
             BookingDesk.provider("phonic",
               enable_assistant_backchannel: false,
               require_speech_before_tool_call: false,
               wait_for_response: false
             )

    assert {:ok, config} = Protocol.start(options, %AudioFormat{})
    assert {:ok, baseline} = Protocol.start([api_key: "booking-test-key"], %AudioFormat{})

    refute config.enable_assistant_backchannel
    refute Map.has_key?(config, :assistant_backchannel_aggressiveness)
    assert config.audio_speed == baseline.audio_speed
    assert config.vad_threshold == baseline.vad_threshold
    assert config.vad_min_speech_duration_ms == baseline.vad_min_speech_duration_ms
    assert [tool] = config.tools
    refute tool.wait_for_response
    refute tool.require_speech_before_tool_call
    assert tool.tool_call_output_timeout_ms == 60_000
  end

  test "disabling backchannels does not implicitly disable busy mode or pre-tool speech" do
    {_, options} =
      BookingDesk.provider("phonic", audio_speed: 1.1, enable_assistant_backchannel: false)

    assert {:ok, config} = Protocol.start(options, %AudioFormat{})
    assert config.audio_speed == 1.1
    refute config.enable_assistant_backchannel
    assert hd(config.tools).wait_for_response
    assert hd(config.tools).require_speech_before_tool_call
  end

  test "session startup enables the matching busy-mode correction policy by default" do
    state = start_booking([])
    assert {Parlora.Providers.Phonic, options} = state.options[:provider]
    assert {:ok, config} = Protocol.start(options, %AudioFormat{})
    assert hd(config.tools).wait_for_response
    assert {BookingDesk.Policy, policy} = state.policy
    assert policy[:phonic_busy]
  end

  test "session startup derives busy mode only from the explicit setting and library default" do
    for {overrides, busy?} <- [
          {[wait_for_response: false], false},
          {[enable_assistant_backchannel: false], true},
          {[require_speech_before_tool_call: false], true}
        ] do
      state = start_booking(provider_options: overrides)
      assert {Parlora.Providers.Phonic, options} = state.options[:provider]
      assert {:ok, config} = Protocol.start(options, %AudioFormat{})
      assert hd(config.tools).wait_for_response == busy?
      assert {BookingDesk.Policy, policy} = state.policy
      assert policy[:phonic_busy] == busy?
    end
  end

  test "session startup rejects the removed combined option before starting a call" do
    assert_raise ArgumentError, fn ->
      BookingDesk.start({StartupChannel, owner: self()}, phonic_native_conversation: false)
    end
  end

  test "the runner rejects the removed combined option before recording or requesting credentials" do
    assert_raise ArgumentError, fn ->
      BookingDesk.Run.run("unused", "unused", phonic_native_conversation: false)
    end
  end

  test "both retired CLI switches produce an option error before starting a call" do
    previous = System.argv()

    try do
      for flag <- ["--phonic-native-conversation", "--no-phonic-native-conversation"] do
        System.argv(["unused", "unused", flag])

        assert_raise OptionParser.ParseError, fn ->
          Code.eval_file(Path.expand("../run.exs", __DIR__))
        end
      end
    after
      System.argv(previous)
    end
  end

  defp start_booking(opts) do
    {:ok, session} =
      BookingDesk.start({StartupChannel, owner: self()}, Keyword.put(opts, :provider, "phonic"))

    on_exit(fn ->
      monitor = Process.monitor(session)
      if Process.alive?(session), do: Parlora.close(session)
      assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, 3_000
    end)

    assert_receive {:channel_starting, _owner}, 1_000
    :sys.get_state(session)
  end
end
