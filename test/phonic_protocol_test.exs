defmodule Parlora.PhonicProtocolTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextUpdate}
  alias Parlora.Providers.Phonic.{Calls, Protocol}

  test "configuration pins the model and codecs with strict asynchronous client delegation" do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      assert {:ok, config} = Protocol.start([api_key: "test"], format)
      assert config.model == "phonic-1"
      assert config.input_format == "pcm_24000" and config.output_format == "pcm_24000"
      refute config.push_to_talk
      refute config.stream_ahead_of_real_time
      refute Map.has_key?(config, :data_retention_policy)
      assert [tool] = config.tools
      assert tool.execution_mode == "async" and tool.wait_for_response == false
      refute tool.allow_tool_chaining
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
