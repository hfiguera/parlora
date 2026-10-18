defmodule Parlora.OpenAIProtocolTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, ContextUpdate, Event, Limits}
  alias Parlora.Providers.OpenAI
  alias Parlora.Providers.OpenAI.Protocol

  test "startup has explicit model, client delegation, one immutable format and no storage" do
    assert {:ok, %{type: "session.start", session: session}} =
             Protocol.start([api_key: "test"], %AudioFormat{})

    assert session.model == "gpt-live-1"
    assert session.delegation == %{type: "client"}
    assert session.store == false
    assert session.audio.format == %{type: "audio/pcm", rate: 24_000}
    assert session.audio.output.voice == "marin"
    refute Map.has_key?(session, :api_key)
    assert {:error, %{code: :invalid_argument}} = Protocol.start([], %AudioFormat{})

    assert {:error, %{code: :unsupported}} =
             Protocol.start([api_key: "test", model: "wrong"], %AudioFormat{})
  end

  test "named and custom voices serialize in both supported audio formats" do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()],
        voice <- ["marin", "cedar", %{id: "voice_test"}, %{"id" => "voice_test"}] do
      assert {:ok, startup} = Protocol.start([api_key: "test", voice: voice], format)
      wire = startup |> Jason.encode!() |> Jason.decode!()
      expected = if is_binary(voice), do: voice, else: %{"id" => "voice_test"}
      assert wire["session"]["audio"]["output"]["voice"] == expected
      assert wire["session"]["store"] == false
      assert wire["session"]["delegation"] == %{"type" => "client"}
    end
  end

  test "malformed voices are rejected locally without accepting unrelated object fields" do
    for voice <- [
          nil,
          false,
          123,
          "",
          [],
          [id: "voice_test"],
          %{},
          %{id: ""},
          %{"id" => nil},
          %{id: 123},
          %{name: "marin"},
          %{id: "voice_test", prompt: "warm"},
          %{:id => "voice_test", "id" => "voice_other"}
        ] do
      assert {:error, %{code: :invalid_argument}} =
               Protocol.start([api_key: "test", voice: voice], %AudioFormat{})
    end

    assert {:error, %{code: :invalid_argument}} =
             Protocol.start(
               [api_key: "test", instructions: %{}, voice: %{id: "voice_test"}],
               %AudioFormat{}
             )
  end

  test "command deadline is a local positive integer option, never a wire field" do
    for invalid <- [0, -1, nil, "1000"] do
      assert {:error, %{code: :invalid_argument}} =
               Protocol.start([api_key: "test", command_ack_timeout_ms: invalid], %AudioFormat{})
    end

    assert {:ok, startup} =
             Protocol.start([api_key: "test", command_ack_timeout_ms: 1000], %AudioFormat{})

    refute inspect(startup) =~ "command_ack_timeout"
  end

  test "history structure is enforced without pretending character counts are token counts" do
    valid = %{
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => "Previous order"}]
    }

    assert {:ok, _start} = Protocol.start([api_key: "test", history: [valid]], %AudioFormat{})

    assert {:error, _error} =
             Protocol.start(
               [api_key: "test", history: [Map.put(valid, "role", "system")]],
               %AudioFormat{}
             )

    assert {:error, _error} =
             Protocol.start(
               [api_key: "test", history: List.duplicate(valid, 129)],
               %AudioFormat{}
             )
  end

  test "append preserves exact content and known nullable delegation references" do
    update = %ContextUpdate{
      id: "update",
      kind: :speakable,
      content: "  é 🇧🇷 result ",
      provider_generation: 0
    }

    assert {:ok, command} = Protocol.append(update, 0, MapSet.new())
    assert command.content == update.content
    assert Map.has_key?(command, :delegation_id)
    assert command.delegation_id == nil

    assert {:error, _error} =
             Protocol.append(%{update | delegation_id: "unknown"}, 0, MapSet.new())

    assert {:error, _error} = Protocol.append(update, 1, MapSet.new())

    assert {:ok, _command} =
             Protocol.append(
               %{update | content: String.duplicate("word ", 1_000)},
               0,
               MapSet.new()
             )
  end

  test "wire events preserve late overlapping transcripts and correlate nullable provider errors" do
    assert {:event, :transcript_delta,
            %{delta: " yes yes ", speaker: :user, start_ms: 100, end_ms: 300}, nil} =
             Protocol.translate(%{
               "type" => "session.input_transcript.delta",
               "delta" => " yes yes ",
               "start_ms" => 100,
               "end_ms" => 300
             })

    assert {:error, "append-1",
            %{message: "Content exceeds 500 tokens", details: %{provider_code: nil}}} =
             Protocol.translate(%{
               "type" => "error",
               "error" => %{
                 "client_event_id" => "append-1",
                 "code" => nil,
                 "message" => "Content exceeds 500 tokens"
               }
             })

    assert {:error, nil, _error} = Protocol.translate(%{"type" => "error", "error" => %{}})

    assert {:ack, :context_acknowledged, "append-1", %{acceptance: :estimated_context_injection}} =
             Protocol.translate(%{
               "type" => "session.commentary.appended",
               "client_event_id" => "append-1"
             })
  end

  test "client delegation includes metadata only and usage remains cumulative" do
    assert {:delegation, %{id: "opaque", offset_ms: 42, target: :client} = payload} =
             Protocol.translate(%{
               "type" => "session.delegation.created",
               "offset_ms" => 42,
               "delegation" => %{"id" => "opaque", "target" => "client"}
             })

    refute Map.has_key?(payload, :input)

    assert {:event, :usage_updated, %{seconds: 12, final?: false}, nil} =
             Protocol.translate(%{
               "type" => "session.usage.updated",
               "usage" => %{"seconds" => 12}
             })

    assert {:closed, %{finalized?: true, reason: "connection_lost"}} =
             Protocol.translate(%{
               "type" => "session.closed",
               "reason" => "connection_lost",
               "usage" => %{"seconds" => 15}
             })
  end

  test "close without append acknowledgment keeps outcomes unknown and usage unfinalized" do
    init = %AdapterInit{
      limits: %Limits{},
      session_id: "s",
      adapter_id: "p",
      generation: 0,
      event_sink: self()
    }

    {:ok, state, _continuation} = OpenAI.init({init, [api_key: "test"], %{}})

    state = %{
      state
      | status: :closing,
        pending: %{"append" => :context, "mute" => :control},
        usage: %{seconds: 7, final?: false}
    }

    assert {:noreply, closed} = OpenAI.handle_info(:close_timeout, state)
    assert closed.status == :closed
    assert closed.key == nil

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_rejected,
                      command_id: "append",
                      payload: %{outcome: :unknown}
                    }}

    assert_receive {:parlora_event,
                    %Event{
                      type: :control_failed,
                      command_id: "mute",
                      payload: %{outcome: :unknown}
                    }}

    assert_receive {:parlora_event,
                    %Event{
                      type: :closed,
                      payload: %{finalized?: false, usage: %{seconds: 7}}
                    }}

    refute_receive {:parlora_event, %Event{type: :usage_final}}, 30
  end
end
