defmodule Parlora.GeminiAdapterTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, ContextUpdate, Event, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.Gemini
  alias Parlora.Providers.Gemini.{Connection, Protocol}
  alias Parlora.TestSupport.TwilioPeer

  defmodule Peer do
    @moduledoc false
    def init(owner) do
      send(owner, {:peer, self()})
      {:ok, owner}
    end

    def handle_in({json, _metadata}, owner) do
      send(owner, {:command, Jason.decode!(json)})
      {:ok, owner}
    end

    def handle_info({:event, event}, owner), do: {:push, {:binary, Jason.encode!(event)}, owner}
  end

  defmodule Route do
    @moduledoc false
    def init(owner), do: owner
    def call(conn, owner), do: conn |> WebSockAdapter.upgrade(Peer, owner, []) |> Plug.Conn.halt()
  end

  setup do
    listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {:ok, peer} = TwilioPeer.connect_headers(port, "/", [])
    assert_receive {:peer, server}

    init = %AdapterInit{
      session_id: "gemini-test",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, config} = Protocol.start([api_key: "secret-test"], init.audio_format)
    {:ok, state, _continue} = Gemini.init({init, [api_key: "secret-test"], config})
    socket = %{conn: peer.conn, ref: peer.ref, ws: peer.websocket, status: 101, headers: []}
    state = %{state | socket: socket, status: :starting}
    on_exit(fn -> Gemini.terminate(:normal, state) end)
    %{state: state, server: server, port: port}
  end

  test "a response delay is observable without socket writes or terminating a late reply",
       context do
    state = %{context.state | status: :ready, response_timeout_ms: 20}

    state =
      deliver(context, state, %{
        "serverContent" => %{"inputTranscription" => %{"text" => "Goodbye"}}
      })

    assert_receive {:gemini_response_deadline, token}, 100
    {:noreply, state} = Gemini.handle_info({:gemini_response_deadline, token}, state)

    assert_receive {:parlora_event,
                    %Event{
                      type: :response_status,
                      payload: %{status: :delayed, cause: :caller_caption}
                    }}

    assert state.status == :ready
    refute_receive {:command, _}, 20
    assert {:noreply, ^state} = Gemini.handle_info({:gemini_response_deadline, token}, state)
    refute_receive {:parlora_event, %Event{type: :response_status}}, 20

    state =
      deliver(context, state, %{
        "serverContent" => %{"outputTranscription" => %{"text" => "Goodbye!"}}
      })

    assert_receive {:parlora_event,
                    %Event{type: :response_status, payload: %{status: :progress_observed}}}

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Goodbye!"}}}

    assert state.response_watch == nil
    assert state.status == :ready
  end

  test "save retries and repeated caller captions cannot postpone or clear the original delay notice",
       context do
    state = %{context.state | status: :ready, response_timeout_ms: 100}

    update = %ContextUpdate{
      id: "save",
      kind: :speakable,
      content: "Order 124 saved",
      provider_generation: 0
    }

    {:reply, :ok, state} = Gemini.handle_call({:append, update}, nil, state)
    original = state.response_watch

    state =
      Enum.reduce(["retry", "clarification"], state, fn id, acc ->
        {:reply, :ok, next} = Gemini.handle_call({:append, %{update | id: id}}, nil, acc)

        next =
          deliver(context, next, %{
            "serverContent" => %{"inputTranscription" => %{"text" => "Hello?"}}
          })

        assert next.response_watch == original
        next
      end)

    token = original.token
    assert_receive {:gemini_response_deadline, ^token}, 500
    {:noreply, state} = Gemini.handle_info({:gemini_response_deadline, token}, state)

    assert_receive {:parlora_event,
                    %Event{
                      type: :response_status,
                      payload: %{status: :delayed, cause: :context_submitted}
                    }}

    {:reply, :ok, state} = Gemini.handle_call({:append, %{update | id: "another"}}, nil, state)
    assert state.response_watch.delayed?
    refute_receive {:parlora_event, %Event{type: :response_status}}, 20

    state =
      deliver(context, state, %{
        "serverContent" => %{"outputTranscription" => %{"text" => "Saved order 124."}}
      })

    assert state.response_watch == nil

    assert_receive {:parlora_event,
                    %Event{type: :response_status, payload: %{status: :progress_observed}}}

    assert {:noreply, ^state} = Gemini.handle_info({:gemini_response_deadline, token}, state)
  end

  test "input, delegation and backend result preserve the deadline until reply or close",
       context do
    state = %{context.state | status: :ready}
    input = fn text -> %{"serverContent" => %{"inputTranscription" => %{"text" => text}}} end
    state = deliver(context, state, input.("Check 123"))
    old = state.response_watch.token
    state = deliver(context, state, input.("Actually 124"))
    assert state.response_watch.token == old
    token = state.response_watch.token
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("slow")]}})
    assert state.response_watch.token == token

    update = %ContextUpdate{
      id: "answer",
      kind: :speakable,
      content: "Order 124 shipped",
      delegation_id: "slow",
      provider_generation: 0
    }

    {:reply, :ok, state} = Gemini.handle_call({:append, update}, nil, state)
    assert state.response_watch.token == token
    assert state.response_watch.cause == :caller_caption
    {:reply, :ok, state} = Gemini.handle_call({:close, "close", :cancel}, nil, state)
    assert state.response_watch == nil
  end

  test "a new call ID associated SILENT cannot hide an outstanding result delay", context do
    state = %{context.state | status: :ready, response_timeout_ms: 100}
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("original")]}})

    update = %ContextUpdate{
      id: "correction-result",
      kind: :speakable,
      content: "Order 123 is shipped",
      delegation_id: "original",
      provider_generation: 0
    }

    {:reply, :ok, state} = Gemini.handle_call({:append, update}, nil, state)
    original_watch = state.response_watch
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("new-id")]}})
    assert state.response_watch == original_watch

    {:reply, :ok, state} =
      Gemini.handle_call(
        {:resolve_delegation, "new-id", %{status: :associated, result_delivery: :unconfirmed}},
        nil,
        state
      )

    assert state.response_watch == original_watch

    assert_receive {:command,
                    %{
                      "toolResponse" => %{
                        "functionResponses" => [%{"id" => "new-id", "scheduling" => "SILENT"}]
                      }
                    }}

    token = original_watch.token
    assert_receive {:gemini_response_deadline, ^token}, 500
    {:noreply, state} = Gemini.handle_info({:gemini_response_deadline, token}, state)
    assert_receive {:parlora_event, %Event{type: :response_status, payload: %{status: :delayed}}}

    # Another duplicate after the warning cannot dismiss it or schedule speech.
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("third-id")]}})

    {:reply, :ok, state} =
      Gemini.handle_call(
        {:resolve_delegation, "third-id", %{status: :associated, result_delivery: :unconfirmed}},
        nil,
        state
      )

    assert state.response_watch.delayed?
    refute_receive {:parlora_event, %Event{type: :response_status}}, 20

    state =
      deliver(context, state, %{
        "serverContent" => %{"outputTranscription" => %{"text" => "Order 123 is shipped."}}
      })

    assert state.response_watch == nil

    assert_receive {:parlora_event,
                    %Event{type: :response_status, payload: %{status: :progress_observed}}}

    assert state.status == :ready
  end

  test "silent association without an outstanding reply creates no phantom deadline", context do
    state = %{context.state | status: :ready}

    state =
      deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("already-answered")]}})

    assert state.response_watch == nil

    {:reply, :ok, state} =
      Gemini.handle_call(
        {:resolve_delegation, "already-answered", %{status: :associated, result_delivery: :done}},
        nil,
        state
      )

    assert state.response_watch == nil
  end

  test "a non-silent delegation resolution starts a reply watch when none exists", context do
    state = %{context.state | status: :ready}
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("rejected")]}})

    {:reply, :ok, state} =
      Gemini.handle_call(
        {:resolve_delegation, "rejected", %{status: :rejected, reason: :capacity}},
        nil,
        state
      )

    assert state.response_watch.cause == :context_submitted
    {:reply, :ok, state} = Gemini.handle_call({:close, "close", :cancel}, nil, state)
    assert state.response_watch == nil
  end

  test "readiness, function response and delivery evidence use the actual socket", context do
    state = deliver(context, context.state, %{"setupComplete" => %{}})
    assert_receive {:parlora_event, %Event{type: :ready}}
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("call-1")]}})

    assert_receive {:parlora_event,
                    %Event{type: :delegation_requested, payload: %{id: "call-1", offset_ms: nil}}}

    update = %ContextUpdate{
      id: "result",
      kind: :speakable,
      content: "Order 124 arrives Friday",
      delegation_id: "call-1",
      provider_generation: 0
    }

    assert {:reply, :ok, state} = Gemini.handle_call({:append, update}, nil, state)

    assert_receive {:command,
                    %{"toolResponse" => %{"functionResponses" => [%{"id" => "call-1"}]}}}

    assert_receive {:parlora_event, %Event{type: :context_submitted, command_id: "result"}}
    refute_received {:parlora_event, %Event{type: :context_acknowledged}}
    assert {:reply, :ok, ^state} = Gemini.handle_call({:append, update}, nil, state)
    refute_receive {:command, _}, 20
    refute inspect(Gemini.format_status(%{state: state})) =~ "secret-test"
  end

  test "caption fragments retain a segment until generation ends, including interruption",
       context do
    state = %{context.state | status: :ready, ever_ready: true}

    state =
      deliver(context, state, %{
        "serverContent" => %{"outputTranscription" => %{"text" => "deliv"}}
      })

    assert_receive {:parlora_event,
                    %Event{
                      type: :transcript_delta,
                      payload: %{segment_id: first, delta: "deliv", start_ms: nil}
                    }}

    state =
      deliver(context, state, %{
        "serverContent" => %{
          "outputTranscription" => %{"text" => "ery."},
          "generationComplete" => true
        }
      })

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{segment_id: ^first, delta: "ery."}}}

    assert state.activity == :unknown
    assert state.speech == :speaking
    assert_receive {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}}
    refute_received {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}}

    state = deliver(context, state, %{"serverContent" => %{"turnComplete" => true}})
    assert state.speech == :idle
    assert_receive {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}}

    state =
      deliver(context, state, %{
        "serverContent" => %{
          "outputTranscription" => %{"text" => "Saved."},
          "interrupted" => true
        }
      })

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{segment_id: second}}}

    refute second == first

    state =
      deliver(context, state, %{
        "serverContent" => %{"outputTranscription" => %{"text" => "Next."}}
      })

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{segment_id: third}}}

    refute third in [first, second]
    assert state.caption_id == third
  end

  test "speech completion does not mark background work idle", context do
    state = %{context.state | status: :ready, ever_ready: true}
    state = deliver(context, state, audio(Base.encode64(:binary.copy(<<1, 0>>, 240))))
    assert state.speech == :speaking
    assert_receive {:parlora_event, %Event{type: :provider_speech, payload: %{state: :speaking}}}
    state = deliver(context, state, %{"serverContent" => %{"generationComplete" => true}})
    assert state.speech == :speaking

    state =
      deliver(context, state, %{
        "serverContent" => %{"turnComplete" => true, "interactionStatus" => "IN_PROGRESS"}
      })

    assert state.speech == :idle
    assert state.activity == :in_progress
    assert state.inbound.bytes > 0
    assert_receive {:parlora_event, %Event{type: :provider_speech, payload: %{state: :idle}}}

    assert_receive {:parlora_event,
                    %Event{type: :provider_activity, payload: %{state: :in_progress}}}
  end

  test "interruption discards old audio and holds new audio until the matching barrier",
       context do
    {:ok, limits} = Limits.new(Gemini.audio_limits())

    state = %{
      context.state
      | status: :ready,
        ever_ready: true,
        init: %{context.state.init | limits: limits},
        inbound: OutputBuffer.new(limits)
    }

    old = Base.encode64(:binary.copy(<<1, 0>>, 480))
    fresh = Base.encode64(:binary.copy(<<2, 0>>, 480))
    state = Enum.reduce(1..100, state, fn _, acc -> deliver(context, acc, audio(old)) end)
    assert state.inbound.bytes == 96_000

    state =
      deliver(
        context,
        state,
        Map.update!(audio(fresh), "serverContent", &Map.put(&1, "interrupted", true))
      )

    assert_receive {:parlora_event, %Event{type: :output_interrupted, payload: %{token: token}}}
    assert {:reply, {:ok, []}, ^state} = Gemini.handle_call({:read, 960}, nil, state)
    assert {:reply, :ok, ^state} = Gemini.handle_call({:resume_output, token - 1}, nil, state)
    assert {:reply, :ok, state} = Gemini.handle_call({:resume_output, token}, nil, state)
    assert {:reply, {:ok, frames}, _state} = Gemini.handle_call({:read, 960}, nil, state)
    assert Enum.map_join(frames, & &1.data) == Base.decode64!(fresh)
  end

  test "long input frames are split across ticks and mute clears queued speech", context do
    init = %{context.state.init | limits: %Limits{max_frame_bytes: 1_920}}
    state = %{context.state | status: :ready, init: init}

    frame =
      Parlora.AudioFrame.new(
        :binary.copy(<<1_000::little-signed-16>>, 960),
        init.audio_format,
        "input",
        0
      )

    assert {:reply, :ok, state} = Gemini.handle_call({:write, frame}, nil, state)
    assert {:noreply, state} = Gemini.handle_info(:send_audio, state)
    assert state.outbound.bytes == 960
    assert_receive {:command, %{"realtimeInput" => %{"audio" => %{"data" => first}}}}
    assert byte_size(Base.decode64!(first)) > 600
    assert {:noreply, state} = Gemini.handle_info(:send_audio, state)
    assert state.outbound.bytes == 0
    assert_receive {:command, %{"realtimeInput" => %{"audio" => _second}}}
    assert {:reply, :ok, state} = Gemini.handle_call({:write, frame}, nil, state)

    assert {:reply, :ok, state} =
             Gemini.handle_call({:control, "mute", {:input_muted, true}}, nil, state)

    assert state.outbound.bytes == 0
    assert {:noreply, _state} = Gemini.handle_info(:send_audio, state)
    assert_receive {:command, %{"realtimeInput" => %{"audio" => %{"data" => muted}}}}
    assert Base.decode64!(muted) == :binary.copy(<<0>>, byte_size(Base.decode64!(muted)))
  end

  test "cancellation rejects late function responses, and close does not fabricate final usage",
       context do
    state = %{context.state | status: :ready, ever_ready: true}
    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("call-1")]}})
    state = deliver(context, state, %{"toolCallCancellation" => %{"ids" => ["call-1"]}})
    assert_receive {:parlora_event, %Event{type: :delegation_cancelled}}

    update = %ContextUpdate{
      id: "late",
      kind: :speakable,
      content: "Old result",
      delegation_id: "call-1",
      provider_generation: 0
    }

    assert {:reply, {:error, _}, state} = Gemini.handle_call({:append, update}, nil, state)
    state = deliver(context, state, %{"usageMetadata" => %{"totalTokenCount" => 123}})
    assert {:reply, :ok, closed} = Gemini.handle_call({:close, "close", :normal}, nil, state)
    assert closed.key == nil and closed.resume_handle == nil

    assert_receive {:parlora_event,
                    %Event{type: :closed, payload: %{finalized?: false, usage: %{final?: false}}}}

    refute_received {:parlora_event, %Event{type: :usage_final}}
  end

  test "a safe GoAway reuses the server handle across a tool turn and keeps call tombstones",
       context do
    state = %{
      context.state
      | status: :ready,
        ever_ready: true,
        connector: fn key, version ->
          Connection.connect(
            key,
            version,
            {:http, "127.0.0.1", context.port}
          )
        end
    }

    state =
      deliver(context, state, %{
        "sessionResumptionUpdate" => %{"newHandle" => "private-handle", "resumable" => true}
      })

    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("finished")]}})

    {:reply, :ok, state} =
      Gemini.handle_call({:resolve_delegation, "finished", %{status: :associated}}, nil, state)

    assert_receive {:command, %{"toolResponse" => _}}
    state = deliver(context, state, %{"serverContent" => %{"turnComplete" => true}})

    state = deliver(context, state, %{"goAway" => %{"timeLeft" => "10s"}})
    assert state.status == :reconnecting and state.reconnects == 1
    assert {:noreply, ^state} = Gemini.handle_info({:reconnect, 0}, state)
    assert {:noreply, state} = Gemini.handle_info({:reconnect, 1}, state)
    refute_received {:parlora_event, %Event{type: :output_interrupted}}
    state = network_step(state)
    assert_receive {:peer, new_server}

    assert_receive {:command,
                    %{"setup" => %{"sessionResumption" => %{"handle" => "private-handle"}}}}

    send(new_server, {:event, %{"setupComplete" => %{}}})
    resumed = network_step(state)
    assert resumed.status == :ready
    assert resumed.calls.records["finished"].status == :completed

    assert_receive {:parlora_event,
                    %Event{
                      type: :provider_connection,
                      payload: %{state: :resumed, continuity: :unverified}
                    }}

    refute_received {:parlora_event, %Event{type: :ready}}
    refute inspect(Gemini.format_status(%{state: resumed})) =~ "private-handle"
    assert {:noreply, ^resumed} = Gemini.handle_info({:go_away_deadline, 0}, resumed)
    Gemini.terminate(:normal, resumed)
  end

  test "pending calls and invalid resumption state close instead of replaying work", context do
    state = %{
      context.state
      | status: :ready,
        ever_ready: true,
        activity: :idle,
        resume_handle: "old",
        resumable: true
    }

    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("pending")]}})

    state =
      deliver(context, state, %{
        "sessionResumptionUpdate" => %{"resumable" => false, "newHandle" => ""}
      })

    assert state.resume_handle == nil
    state = deliver(context, state, %{"goAway" => %{"timeLeft" => "0s"}})
    assert {:noreply, closed} = Gemini.handle_info({:go_away_deadline, 0}, state)
    assert closed.status == :closed and closed.reconnects == 0

    assert_receive {:parlora_event,
                    %Event{
                      type: :failed,
                      payload: %{error: %{details: %{reason: :resumption_unsafe}}}
                    }}
  end

  test "turn completion cannot resume pending work and audio revokes the idle boundary",
       context do
    state = %{
      context.state
      | status: :ready,
        ever_ready: true,
        resumable: true,
        resume_handle: "private-handle",
        go_away: true
    }

    state = deliver(context, state, %{"toolCall" => %{"functionCalls" => [call("pending")]}})
    state = deliver(context, state, %{"serverContent" => %{"turnComplete" => true}})
    assert state.status == :ready and state.activity == :idle
    assert state.calls.records["pending"].status == :pending
    state = deliver(context, state, audio(Base.encode64(:binary.copy(<<1, 0>>, 480))))
    assert state.activity == :in_progress and state.status == :ready
  end

  defp network_step(state) do
    socket = Mint.HTTP.get_socket(state.socket.conn)

    receive do
      {:tcp, ^socket, _bytes} = message ->
        {:noreply, next} = Gemini.handle_info(message, state)
        next
    after
      2_000 -> flunk("No local WebSocket response")
    end
  end

  defp call(id),
    do: %{"id" => id, "name" => Protocol.function(), "args" => %{"request" => "order 124"}}

  defp audio(encoded),
    do: %{
      "serverContent" => %{
        "modelTurn" => %{
          "parts" => [
            %{"inlineData" => %{"mimeType" => "audio/pcm;rate=24000", "data" => encoded}}
          ]
        }
      }
    }

  defp deliver(context, state, event) do
    send(context.server, {:event, event})
    socket = Mint.HTTP.get_socket(state.socket.conn)
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    {:noreply, next} = Gemini.handle_info({:tcp, socket, bytes}, state)
    next
  end
end
