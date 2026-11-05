defmodule Parlora.GrokSettingsTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextUpdate}
  alias Parlora.Providers.Grok.Protocol

  @settings [
    language_hint: "EN",
    keyterms: ["Cedarwood", "Dr. Lee"],
    replace: %{"Cedarwood" => "Cedar wood"},
    speed: 1.05,
    idle_timeout_ms: 8_000
  ]

  test "native settings map to their documented fields in both pipeline formats" do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, %{setup: %{session: session}}} =
               Protocol.start([api_key: "test"] ++ @settings, format)

      assert session.audio.input.transcription == %{
               model: "grok-transcribe",
               language_hint: "en",
               keyterms: ["Cedarwood", "Dr. Lee"]
             }

      assert session.audio.output.speed == 1.05
      assert session.replace == %{"Cedarwood" => "Cedar wood"}
      assert session.turn_detection == %{type: "server_vad", idle_timeout_ms: 8_000}
      assert session.resumption == %{enabled: false}
      assert [_function] = session.tools
    end
  end

  test "defaults do not send new settings and explicit disabling remains available" do
    {:ok, %{setup: %{session: session}}} = Protocol.start([api_key: "test"], %AudioFormat{})
    assert session.audio.input.transcription == %{model: "grok-transcribe"}
    assert session.audio.output == %{format: %{type: "audio/pcm", rate: 24_000}}
    assert session.turn_detection == %{type: "server_vad"}
    refute Map.has_key?(session, :replace)

    {:ok, %{setup: %{session: session}}} =
      Protocol.start(
        [
          api_key: "test",
          language_hint: nil,
          keyterms: [],
          replace: %{},
          speed: 1,
          idle_timeout_ms: nil
        ],
        %AudioFormat{}
      )

    assert session.turn_detection.idle_timeout_ms == nil
    assert session.audio.output.speed == 1
  end

  test "malformed settings fail at startup without raising" do
    for {key, invalid} <- [
          language_hint: "es",
          language_hint: "pt",
          language_hint: "not-a-language",
          language_hint: 42,
          language_hint: <<255>>,
          keyterms: nil,
          keyterms: "Cedarwood",
          keyterms: [1],
          keyterms: [" "],
          keyterms: [<<255>>],
          keyterms: ["yes" | :invalid],
          keyterms: List.duplicate("name", 101),
          keyterms: [String.duplicate("名", 51)],
          replace: [],
          replace: %{name: "value"},
          replace: %{"name" => nil},
          replace: %{"name" => " "},
          replace: %{<<255>> => "value"},
          replace: Map.new(1..5, &{Integer.to_string(&1), String.duplicate("x", 16_384)}),
          speed: 0.69,
          speed: 1.51,
          speed: nil,
          speed: "1.0",
          idle_timeout_ms: 0,
          idle_timeout_ms: -1,
          idle_timeout_ms: 8.0,
          idle_timeout_ms: true,
          invented: true
        ] do
      assert {:error, %{code: :invalid_argument}} =
               Protocol.start([{:api_key, "test"}, {key, invalid}], %AudioFormat{})
    end

    for options <- [nil, %{}, [:invalid], [{:api_key, "test"} | :invalid]] do
      assert {:error, %{code: :invalid_argument}} = Protocol.start(options, %AudioFormat{})
    end
  end

  test "documented boundaries accept unicode keyterms and regional language codes" do
    for speed <- [0.7, 1.5] do
      assert {:ok, %{setup: %{session: session}}} =
               Protocol.start(
                 [
                   api_key: "test",
                   speed: speed,
                   language_hint: "es-mx",
                   keyterms: List.duplicate(String.duplicate("名", 50), 100)
                 ],
                 %AudioFormat{}
               )

      assert session.audio.input.transcription.language_hint == "es-MX"
    end
  end

  test "readiness rejects ignored settings and malformed acknowledgments" do
    {:ok, %{setup: %{session: expected}}} =
      Protocol.start([api_key: "test"] ++ @settings, %AudioFormat{})

    actual = expected |> Map.put(:model, Protocol.model()) |> JSON.encode!() |> JSON.decode!()
    assert Protocol.configured?(actual, expected)

    for path <- [
          ["replace"],
          ["audio", "output", "speed"],
          ["audio", "input", "transcription", "language_hint"],
          ["audio", "input", "transcription", "keyterms"],
          ["turn_detection", "idle_timeout_ms"]
        ] do
      refute Protocol.configured?(put_in(actual, path, nil), expected)
    end

    refute Protocol.configured?(%{actual | "audio" => "malformed"}, expected)
    refute Protocol.configured?(%{actual | "audio" => nil}, expected)

    {:ok, %{setup: %{session: disabled}}} =
      Protocol.start([api_key: "test", idle_timeout_ms: nil], %AudioFormat{})

    refute Protocol.configured?(actual, disabled)
  end

  test "verbatim text is explicit, bounded, interruptible and separate from delegation results" do
    update = %ContextUpdate{
      id: "say",
      kind: :verbatim,
      provider_generation: 0,
      content: "Zero one eight eight."
    }

    assert Protocol.validate(update, 0) == :ok

    assert Protocol.verbatim(update.content).item == %{
             type: "force_message",
             role: "assistant",
             interruptible: true,
             content: [%{type: "output_text", text: "Zero one eight eight."}]
           }

    for changed <- [
          %{update | content: ""},
          %{update | content: " "},
          %{update | content: <<255>>},
          %{update | content: String.duplicate("x", 16_385)},
          %{update | delegation_id: "call"},
          %{update | provider_generation: 1}
        ] do
      assert {:error, %{code: :invalid_argument}} = Protocol.validate(changed, 0)
    end
  end

  test "native acknowledgments may omit empty replacements and a disabled idle timeout" do
    {:ok, %{setup: %{session: expected}}} =
      Protocol.start(
        [api_key: "test", replace: %{}, keyterms: [], speed: 1, idle_timeout_ms: nil],
        %AudioFormat{}
      )

    actual = %{
      "model" => Protocol.model(),
      "reasoning" => %{"effort" => "high"},
      "turn_detection" => %{"type" => "server_vad"},
      "audio" => %{
        "input" => %{"transcription" => %{"keyterms" => []}},
        "output" => %{"speed" => 1.0}
      }
    }

    assert Protocol.configured?(actual, expected)
    refute Protocol.configured?(Map.put(actual, "replace", %{"one" => "two"}), expected)

    refute Protocol.configured?(
             put_in(actual, ["turn_detection", "idle_timeout_ms"], 8_000),
             expected
           )
  end
end
