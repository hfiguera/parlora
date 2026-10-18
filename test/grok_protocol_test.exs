defmodule Parlora.GrokProtocolTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextUpdate}
  alias Parlora.Providers.Grok.{Calls, Protocol, Transcripts}

  test "pinned setup explicitly selects reasoning and both supported codecs" do
    for {format, codec} <- [{%AudioFormat{}, "audio/pcm"}, {AudioFormat.pcmu(), "audio/pcmu"}],
        reasoning <- [:high, :none] do
      assert {:ok, %{setup: %{session: session}}} =
               Protocol.start([api_key: "test", reasoning_effort: reasoning], format)

      assert session.reasoning.effort == Atom.to_string(reasoning)
      assert session.audio.input.format.type == codec
      assert session.audio.output.format == session.audio.input.format
      assert session.resumption.enabled == false
      assert session.tools |> hd() |> Map.fetch!(:name) == Protocol.function()
    end

    assert Protocol.model() == "grok-voice-3.0"
    assert Protocol.path() == "/v1/realtime?model=grok-voice-3.0"

    assert {:ok, %{setup: %{session: %{reasoning: %{effort: "high"}}}}} =
             Protocol.start([api_key: "test"], %AudioFormat{})

    refute Protocol.capabilities().usage?
    refute Protocol.capabilities().context_acknowledgment?
    assert Protocol.capabilities().context_update_kinds == [:speakable]
  end

  test "configuration and context reject unsupported or stale settings" do
    for options <- [
          [],
          [api_key: ""],
          [api_key: "test", reasoning_effort: :low],
          [api_key: "test", history: [%{}]]
        ] do
      assert {:error, %{code: :invalid_argument}} = Protocol.start(options, %AudioFormat{})
    end

    for model <- ["grok-voice-latest", "grok-voice-think-fast-2.0", "grok-voice-think-fast-3.0"] do
      assert {:error, %{code: :unsupported}} =
               Protocol.start([api_key: "test", model: model], %AudioFormat{})
    end

    update = %ContextUpdate{
      id: "command",
      content: "Fact",
      provider_generation: 2,
      kind: :speakable
    }

    assert :ok = Protocol.validate(update, 2)
    assert {:error, %{code: :invalid_argument}} = Protocol.validate(update, 1)
    assert {:error, %{code: :unsupported}} = Protocol.validate(%{update | kind: :quiet}, 2)
  end

  test "cumulative corrected transcripts are finalized once after commitment" do
    records = Transcripts.new(1)
    event = fn type, text -> %{"type" => type, "item_id" => "caller", "transcript" => text} end
    completed = "conversation.item.input_audio_transcription.completed"
    assert {:ok, nil, records} = Transcripts.observe(records, event.(completed, "Order 123"))

    assert {:ok, nil, records} =
             Transcripts.observe(
               records,
               event.("conversation.item.input_audio_transcription.updated", "Order 124")
             )

    assert {:ok, nil, records} =
             Transcripts.observe(records, %{
               "type" => "input_audio_buffer.committed",
               "item_id" => "caller"
             })

    assert {:ok, caption, records} = Transcripts.observe(records, event.(completed, "Order 124"))
    assert caption.delta == "Order 124"
    assert caption.start_ms == nil and caption.end_ms == nil
    assert {:ok, nil, ^records} = Transcripts.observe(records, event.(completed, "Order 124"))

    assert {:error, %{code: :adapter_failed}} =
             Transcripts.observe(records, event.(completed, "Order 125"))

    assert {:error, %{code: :backpressure}} =
             Transcripts.observe(records, %{event.(completed, "Other") | "item_id" => "other"})
  end

  test "call tombstones reject conflicting IDs and late superseded results" do
    call = %{
      "name" => Protocol.function(),
      "call_id" => "call",
      "arguments" => Jason.encode!(%{request: "order 123"})
    }

    assert {:new, %{"request" => "order 123"}, records} = Calls.admit(Calls.new(1), call)
    assert {:duplicate, ^records} = Calls.admit(records, call)

    assert {:error, %{code: :invalid_argument}} =
             Calls.admit(records, %{call | "arguments" => Jason.encode!(%{request: "order 124"})})

    assert {:error, %{code: :backpressure}} = Calls.admit(records, %{call | "call_id" => "other"})
    assert {:ok, command, records} = Calls.complete(records, "call", %{status: :superseded})
    assert command.item.call_id == "call"
    assert Jason.decode!(command.item.output) == %{"status" => "superseded"}
    assert records.records["call"].status == :superseded
    assert {:error, _} = Calls.context(records, "call", "Obsolete result")
    assert {:error, _} = Calls.context(records, "unknown", "Result")
  end

  test "clarification closes a call once and later results use a new application turn" do
    call = %{
      "name" => Protocol.function(),
      "call_id" => "clarify",
      "arguments" => Jason.encode!(%{request: "order"})
    }

    {:new, _args, records} = Calls.admit(Calls.new(4), call)

    assert {:ok, %{item: %{type: "function_call_output"}}, records} =
             Calls.context(records, "clarify", "Which order?")

    assert {:ok, %{item: %{type: "message"}}, ^records} =
             Calls.context(records, "clarify", "Current result")

    assert {:error, _} = Calls.complete(records, "clarify", %{status: :associated})
  end
end
