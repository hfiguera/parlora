defmodule Parlora.OpenAIShutdownTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioQueue, Event, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI
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

    def handle_info({:event, event}, owner),
      do: {:push, {:text, Jason.encode!(event)}, owner}
  end

  defmodule Route do
    @moduledoc false
    def init(owner), do: owner

    def call(conn, owner),
      do: conn |> WebSockAdapter.upgrade(Peer, owner, []) |> Plug.Conn.halt()
  end

  setup do
    listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {:ok, peer} = TwilioPeer.connect_headers(port, "/", [])
    assert_receive {:peer, server}

    init = %AdapterInit{
      session_id: "shutdown",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, state, _continue} = OpenAI.init({init, [api_key: "test"], %{}})
    state = %{state | conn: peer.conn, websocket: peer.websocket, ref: peer.ref, status: :ready}

    stale_at =
      System.monotonic_time(:microsecond) - (init.limits.provider_audio_max_age_ms + 1) * 1_000

    pcm = AudioFormat.silence(init.audio_format, 10)
    {:ok, {inbound, _sequence}} = OutputBuffer.push(state.inbound, pcm, init, 0, stale_at)
    frame = AudioFrame.new(pcm, init.audio_format, init.adapter_id, 0)
    {:ok, outbound} = AudioQueue.push(state.outbound, frame)
    on_exit(fn -> Mint.HTTP.close(peer.conn) end)

    %{
      state: %{state | inbound: inbound, outbound: outbound},
      server: server,
      pcm: pcm,
      port: port
    }
  end

  test "new audio fires the armed hint once without changing queued data", context do
    state = %{context.state | inbound: AudioQueue.clear(context.state.inbound)}
    reference = make_ref()
    {:reply, :ok, state} = OpenAI.handle_call({:arm_output_ready, self(), reference}, nil, state)
    next = deliver(context.server, state, audio(Base.encode64(context.pcm)))
    assert_receive {:parlora_audio_ready, source, ^reference}
    assert source == self()
    assert next.audio_waiter == nil
    next = deliver(context.server, next, audio(Base.encode64(context.pcm)))
    refute_received {:parlora_audio_ready, _, ^reference}
    {:reply, {:ok, frames}, _} = OpenAI.handle_call({:read, 960}, nil, next)
    assert Enum.map_join(frames, & &1.data) == context.pcm <> context.pcm
  end

  test "close releases audio and accepts final usage despite late audio", context do
    state = %{context.state | pending: %{"result-1" => :context}}
    {:reply, :ok, closing} = OpenAI.handle_call({:close, "close-1", :cancel}, nil, state)
    assert closing.status == :closing
    assert closing.inbound.bytes == 0
    assert closing.outbound.bytes == 0
    assert_receive {:command, %{"type" => "session.close", "event_id" => "close-1"}}

    # Exceed receive capacity as well as the old queue's age limit. Once closing,
    # neither tail audio nor malformed base64 should abort usage finalization.
    large = :binary.copy(context.pcm, 200)
    closing = deliver(context.server, closing, audio(Base.encode64(large)))
    closing = deliver(context.server, closing, audio("invalid base64"))
    assert closing.status == :closing
    assert closing.inbound.bytes == 0
    refute_received {:parlora_event, %Event{type: :failed}}
    refute_received {:parlora_event, %Event{type: :audio_discontinuity}}

    closing =
      deliver(context.server, closing, %{
        "type" => "session.commentary.appended",
        "client_event_id" => "result-1"
      })

    assert closing.pending == %{}
    assert_receive {:parlora_event, %Event{type: :context_acknowledged, command_id: "result-1"}}

    closed =
      deliver(context.server, closing, %{
        "type" => "session.closed",
        "reason" => "client_requested",
        "usage" => %{"seconds" => 83}
      })

    assert closed.status == :closed
    assert closed.finalized

    assert_receive {:parlora_event,
                    %Event{type: :usage_final, payload: %{seconds: 83, final?: true}}}

    assert_receive {:parlora_event, %Event{type: :closed, payload: %{finalized?: true}}}
    assert {:noreply, ^closed} = OpenAI.handle_info(:close_timeout, closed)
  end

  test "late audio cannot remove the finite close deadline", context do
    {:reply, :ok, closing} = OpenAI.handle_call({:close, "close-2", :cancel}, nil, context.state)
    closing = deliver(context.server, closing, audio(Base.encode64(context.pcm)))

    assert {:noreply, %{status: :closed, finalized: false}} =
             OpenAI.handle_info(:close_timeout, closing)

    assert_receive {:parlora_event,
                    %Event{type: :closed, payload: %{finalized?: false, reason: :timeout}}}

    refute_received {:parlora_event, %Event{type: :usage_final}}
  end

  test "active sessions request recoverable transport replacement on stale audio", context do
    recovering = deliver(context.server, context.state, audio(Base.encode64(context.pcm)))
    assert recovering.status == :recovering

    assert_receive {:parlora_event,
                    %Event{type: :output_recovery_requested, payload: %{cause: :output_stale}}}

    refute_received {:parlora_event, %Event{type: :failed}}
    refute_received {:parlora_event, %Event{type: :closed}}
  end

  test "a sustained burst producer reaches a bounded recovery, then tail audio and commands stay isolated",
       context do
    state = %{context.state | inbound: AudioQueue.clear(context.state.inbound)}
    pcm = AudioFormat.silence(state.init.audio_format, 100)

    state =
      Enum.reduce(1..8, state, fn _, state ->
        deliver(context.server, state, audio(Base.encode64(pcm)))
      end)

    assert state.status == :recovering
    assert state.inbound.bytes == 0
    assert state.outbound.capacity == state.init.limits.audio_queue_bytes

    assert_receive {:parlora_event,
                    %Event{type: :output_recovery_requested, payload: %{token: 1}}}

    state = deliver(context.server, state, audio(Base.encode64(pcm)))

    state =
      deliver(context.server, state, %{
        "type" => "session.delegation.created",
        "delegation" => %{"id" => "stale", "target" => "client"},
        "offset_ms" => 0
      })

    assert state.inbound.bytes == 0
    refute_received {:parlora_event, %Event{type: :delegation_requested}}
    refute_received {:parlora_event, %Event{type: :failed}}
    {:reply, {:ok, []}, state} = OpenAI.handle_call({:read, 960}, nil, state)
    {:reply, :ok, state} = OpenAI.handle_call({:arm_output_ready, self(), make_ref()}, nil, state)
    frame = AudioFrame.new(context.pcm, state.init.audio_format, "caller", 0)
    {:reply, :ok, state} = OpenAI.handle_call({:write, frame}, nil, state)
    assert state.outbound.bytes == 0
    assert state.recovery.dropped_input_bytes >= byte_size(context.pcm)
    assert {:noreply, ^state} = OpenAI.handle_info({:send_audio, -1}, state)
    assert {:noreply, ^state} = OpenAI.handle_info({:output_recovery_timeout, 0}, state)
  end

  test "fresh voice transport remaps old delegation results and rebases captions",
       context do
    state = %{
      context.state
      | inbound: AudioQueue.clear(context.state.inbound),
        status: :starting_recovery,
        recovery: %{token: 1, dropped_input_bytes: 0},
        transport_epoch: 1,
        timeline_offset_ms: 10_000,
        timeline_end_ms: 10_000,
        recovery_awaiting_user: true,
        delegations: MapSet.new(["old-call"]),
        retired_delegations: MapSet.new(["old-call"])
    }

    update = %Parlora.ContextUpdate{
      id: "completed-result",
      kind: :speakable,
      content: "The operation completed once",
      provider_generation: 0,
      delegation_id: "old-call"
    }

    {:reply, :ok, state} = OpenAI.handle_call({:append, update}, nil, state)
    refute_receive {:command, %{"event_id" => "completed-result"}}, 20

    state =
      deliver(context.server, state, %{
        "type" => "session.started",
        "session" => %{"id" => "replacement"}
      })

    assert state.status == :ready and state.recovery == nil
    assert_receive {:parlora_event, %Event{type: :output_recovered, payload: %{token: 1}}}
    refute_receive {:command, %{"event_id" => "completed-result"}}, 20

    state =
      deliver(context.server, state, %{
        "type" => "session.delegation.created",
        "delegation" => %{"id" => "automatic-retry", "target" => "client"},
        "offset_ms" => 0
      })

    refute_received {:parlora_event, %Event{type: :delegation_requested}}

    state =
      deliver(context.server, state, %{
        "type" => "session.delegation.created",
        "delegation" => %{"id" => "early-new-call", "target" => "client"},
        "offset_ms" => 300
      })

    refute_received {:parlora_event, %Event{type: :delegation_requested}}

    state =
      deliver(context.server, state, %{
        "type" => "session.input_transcript.delta",
        "delta" => "Continue",
        "start_ms" => 100,
        "end_ms" => 500
      })

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{start_ms: 10_100, end_ms: 10_500}}}

    assert_receive {:parlora_event,
                    %Event{
                      type: :delegation_requested,
                      payload: %{id: "early-new-call", offset_ms: 10_300}
                    }}

    assert_receive {:command, %{"event_id" => "completed-result", "delegation_id" => nil}}

    refute_received {:parlora_event,
                     %Event{type: :delegation_requested, payload: %{id: "automatic-retry"}}}

    state =
      deliver(context.server, state, %{
        "type" => "session.delegation.created",
        "delegation" => %{"id" => "new-call", "target" => "client"},
        "offset_ms" => 500
      })

    assert_receive {:parlora_event,
                    %Event{
                      type: :delegation_requested,
                      payload: %{id: "new-call", offset_ms: 10_500}
                    }}

    state = deliver(context.server, state, audio(Base.encode64(context.pcm)))
    assert state.inbound.bytes == byte_size(context.pcm)
    assert {:noreply, ^state} = OpenAI.handle_info({:output_recovery_timeout, 1}, state)
    refute_received {:parlora_event, %Event{type: :ready}}
    refute_received {:parlora_event, %Event{type: :failed}}
  end

  test "another recovery retains unsent updates and tracks their eventual acknowledgment",
       context do
    state = %{context.state | transport_epoch: 1, recovery_awaiting_user: true}

    update = %Parlora.ContextUpdate{
      id: "held-result",
      kind: :speakable,
      content: "Verified result",
      provider_generation: 0
    }

    {:reply, :ok, state} = OpenAI.handle_call({:append, update}, nil, state)
    {:reply, {:ok, []}, state} = OpenAI.handle_call({:read, 960}, nil, state)
    assert state.status == :recovering
    assert state.pending[update.id] == :context
    refute_received {:parlora_event, %Event{command_id: "held-result", type: :context_rejected}}

    assert {:reply, {:error, %{code: :invalid_argument}}, ^state} =
             OpenAI.handle_call({:read, 0}, nil, state)

    state = %{state | status: :starting_recovery, transport_epoch: 2}

    state =
      deliver(context.server, state, %{
        "type" => "session.started",
        "session" => %{"id" => "second"}
      })

    refute_receive {:command, %{"event_id" => "held-result"}}, 20

    state =
      deliver(context.server, state, %{
        "type" => "session.input_transcript.delta",
        "delta" => "Continue",
        "start_ms" => 0,
        "end_ms" => 100
      })

    assert_receive {:command, %{"event_id" => "held-result"}}
    assert state.pending[update.id] == :context

    state =
      deliver(context.server, state, %{
        "type" => "session.commentary.appended",
        "client_event_id" => update.id
      })

    refute Map.has_key?(state.pending, update.id)

    assert_receive {:parlora_event,
                    %Event{command_id: "held-result", type: :context_acknowledged}}
  end

  test "transport remapping preserves an already admitted update's duplicate identity", context do
    state = %{context.state | delegations: MapSet.new(["old-call"])}

    update = %Parlora.ContextUpdate{
      id: "same-result",
      kind: :quiet,
      content: "Completed once",
      provider_generation: 0,
      delegation_id: "old-call"
    }

    {:reply, :ok, state} = OpenAI.handle_call({:append, update}, nil, state)

    assert_receive {:command, %{"event_id" => "same-result", "delegation_id" => "old-call"}}

    state = %{state | retired_delegations: state.delegations}
    assert {:reply, :ok, ^state} = OpenAI.handle_call({:append, update}, nil, state)
    refute_receive {:command, %{"event_id" => "same-result"}}, 20
  end

  test "replacement connector transfers socket ownership and completes a fresh handshake",
       context do
    alias Parlora.Providers.OpenAI.{Protocol, Recovery}

    {worker, monitor} =
      Recovery.connect(self(), 1, "test", {:http, "127.0.0.1", context.port, "/"})

    assert_receive {:peer, server}
    assert_receive {:output_connection, 1, {:ok, conn, ref}}

    {:ok, original} =
      Protocol.start(
        [api_key: "test", voice: %{id: "voice_recovery"}, instructions: "A warm adult voice."],
        context.state.init.audio_format
      )

    startup = Recovery.startup(original, %Parlora.ContextSnapshot{})

    state = %{
      context.state
      | conn: nil,
        websocket: nil,
        ref: nil,
        headers: [],
        http_status: nil,
        status: :connecting_recovery,
        recovery: %{token: 1, dropped_input_bytes: 0},
        startup: startup,
        connection_worker: {worker, monitor},
        transport_epoch: 1,
        inbound: AudioQueue.clear(context.state.inbound)
    }

    {:noreply, state} = OpenAI.handle_info({:output_connection, 1, {:ok, conn, ref}}, state)
    state = receive_active(state)
    assert state.status == :starting_recovery

    assert_receive {:command,
                    %{
                      "type" => "session.start",
                      "session" => %{
                        "audio" => %{"output" => %{"voice" => %{"id" => "voice_recovery"}}},
                        "instructions" => "A warm adult voice."
                      }
                    }}

    send(server, {:event, %{"type" => "session.started", "session" => %{"id" => "new-session"}}})
    state = receive_active(state)
    assert state.status == :ready
    assert_receive {:parlora_event, %Event{type: :output_recovered}}
    refute_received {:parlora_event, %Event{type: :failed}}
    assert :ok = OpenAI.terminate(:normal, state)
  end

  test "usage from an interrupted transport stays incomplete after the replacement finalizes",
       context do
    state = %{
      context.state
      | status: :starting_recovery,
        recovery: %{token: 1, dropped_input_bytes: 0},
        prior_usage_seconds: 20,
        usage_complete?: false
    }

    state =
      deliver(context.server, state, %{
        "type" => "session.started",
        "session" => %{"id" => "replacement"}
      })

    state =
      deliver(context.server, state, %{
        "type" => "session.closed",
        "reason" => "close_requested",
        "usage" => %{"seconds" => 5}
      })

    assert state.usage.seconds == 25

    assert_receive {:parlora_event,
                    %Event{type: :usage_final, payload: %{seconds: 25, complete?: false}}}

    assert_receive {:parlora_event, %Event{type: :closed, payload: %{finalized?: false}}}
  end

  test "only a failed replacement transport reaches the finite fatal deadline", context do
    state = %{context.state | status: :recovering, recovery: %{token: 1}}
    {:noreply, closed} = OpenAI.handle_info({:output_recovery_timeout, 1}, state)
    assert closed.status == :closed
    assert_receive {:parlora_event, %Event{type: :failed, payload: %{cause: :recovery_timeout}}}
  end

  test "diagnostics observe unknown caption shapes and captions during closure", context do
    alias Parlora.Providers.OpenAI.Diagnostics
    state = %{context.state | diagnostics: Diagnostics.new(self())}
    frame = AudioFrame.new(context.pcm, state.init.audio_format, state.init.adapter_id, 1)
    {:reply, :ok, state} = OpenAI.handle_call({:write, frame}, nil, state)
    {:noreply, state} = OpenAI.handle_info(:send_audio, state)

    state =
      deliver(context.server, state, %{
        "type" => "session.input_transcript.delta",
        "delta" => "unhandled: no offsets"
      })

    refute_received {:parlora_event, %Event{type: :transcript_delta}}
    {:reply, :ok, state} = OpenAI.handle_call({:close, "diagnostic-close", :finish}, nil, state)

    state =
      deliver(context.server, state, %{
        "type" => "session.input_transcript.delta",
        "delta" => "late caption",
        "start_ms" => 0,
        "end_ms" => 200
      })

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "late caption"}}}

    state =
      deliver(context.server, state, %{
        "type" => "session.closed",
        "reason" => "client_requested",
        "usage" => %{}
      })

    assert state.diagnostics == nil
    assert_receive {:parlora_provider_diagnostics, report}
    assert report.accepted_audio_bytes == byte_size(context.pcm)
    assert report.sent_audio_bytes >= byte_size(context.pcm)
    assert Enum.any?(report.events, &(&1[:delta] == "unhandled: no offsets"))
    assert Enum.any?(report.events, &(&1[:delta] == "late caption"))
    assert List.last(report.events).type == "session.closed"
    assert :ok == OpenAI.terminate(:normal, state)
    refute_received {:parlora_provider_diagnostics, _}
  end

  test "missing command acknowledgment closes instead of remaining ready", context do
    state = %{context.state | command_ack_timeout_ms: 25}

    update = %Parlora.ContextUpdate{
      id: "silent-greeting",
      kind: :instruction,
      content: "Greet now",
      provider_generation: 0
    }

    {:reply, :ok, state} = OpenAI.handle_call({:append, update}, nil, state)
    assert_receive {:command, %{"event_id" => "silent-greeting"}}
    assert_receive {:command_ack_timeout, "silent-greeting"} = timeout
    {:noreply, closed} = OpenAI.handle_info(timeout, state)
    assert closed.status == :closed
    assert closed.pending == %{}

    assert_receive {:parlora_event,
                    %Event{type: :failed, payload: %{cause: :command_ack_timeout}}}

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_rejected,
                      command_id: "silent-greeting",
                      payload: %{outcome: :unknown}
                    }}

    assert_receive {:parlora_event, %Event{type: :closed}}
    assert {:noreply, ^closed} = OpenAI.handle_info(timeout, closed)
    refute_received {:parlora_event, %Event{type: :failed}}
  end

  test "acknowledged or rejected commands and shutdown ignore stale deadlines", context do
    for outcome <- [:ack, :reject, :closing] do
      state = %{context.state | pending: %{"context" => :context}}

      state =
        case outcome do
          :ack ->
            deliver(context.server, state, %{
              "type" => "session.instructions.appended",
              "client_event_id" => "context"
            })

          :reject ->
            deliver(context.server, state, %{
              "type" => "error",
              "error" => %{"client_event_id" => "context", "message" => "rejected"}
            })

          :closing ->
            %{state | status: :closing}
        end

      assert {:noreply, ^state} = OpenAI.handle_info({:command_ack_timeout, "context"}, state)
      refute_received {:parlora_event, %Event{type: :failed}}
    end
  end

  defp audio(encoded), do: %{"type" => "session.output_audio.delta", "delta" => encoded}

  defp deliver(server, state, event) do
    send(server, {:event, event})
    receive_frame(state)
  end

  defp receive_active(state) do
    socket = Mint.HTTP.get_socket(state.conn)

    receive do
      {:tcp, ^socket, _bytes} = message ->
        {:noreply, next} = OpenAI.handle_info(message, state)

        if next.websocket == nil or next.websocket.buffer != <<>> or
             next.websocket.fragment != nil, do: receive_active(next), else: next
    after
      2_000 -> flunk("replacement socket did not deliver a complete event")
    end
  end

  defp receive_frame(state) do
    socket = Mint.HTTP.get_socket(state.conn)
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    {:noreply, next} = OpenAI.handle_info({:tcp, socket, bytes}, state)

    case next.websocket do
      %{buffer: buffer, fragment: fragment} when buffer != <<>> or fragment != nil ->
        receive_frame(next)

      _complete ->
        next
    end
  end
end
