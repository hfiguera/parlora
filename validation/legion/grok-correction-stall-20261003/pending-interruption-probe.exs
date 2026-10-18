defmodule Parlora.GrokPendingInterruptionProbe do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, Limits}
  alias Parlora.Providers.Grok
  alias Parlora.Providers.Grok.Protocol
  alias Parlora.TestSupport.TwilioPeer

  defmodule WirePeer do
    @moduledoc false
    def init(owner),
      do:
        (
          send(owner, {:grok_peer, self()})
          {:ok, owner}
        )

    def handle_in({json, _metadata}, owner),
      do:
        (
          send(owner, {:grok_command, Jason.decode!(json)})
          {:ok, owner}
        )

    def handle_info({:grok_event, event}, owner),
      do: {:push, {:text, Jason.encode!(event)}, owner}
  end

  defmodule Route do
    @moduledoc false
    def init(owner), do: owner

    def call(conn, owner),
      do: conn |> WebSockAdapter.upgrade(WirePeer, owner, []) |> Plug.Conn.halt()
  end

  setup do
    listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {:ok, peer} = TwilioPeer.connect_headers(port, Protocol.path(), [])
    assert_receive {:grok_peer, server}

    init = %AdapterInit{
      session_id: "grok-test",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, config} = Protocol.start([api_key: "private-test"], init.audio_format)
    {:ok, state, _continue} = Grok.init({init, [api_key: "private-test"], config})

    state = %{
      state
      | socket: %{conn: peer.conn, ref: peer.ref, ws: peer.websocket, status: 101, headers: []},
        status: :starting
    }

    on_exit(fn -> Grok.terminate(:normal, state) end)
    %{state: state, server: server}
  end

  test "ready requires configuration acknowledgment and diagnostics redact keys", context do
    assert {:reply, {:error, %{code: :not_ready}}, _} =
             Grok.handle_call(:capabilities, nil, context.state)

    state = deliver(context, context.state, %{"type" => "session.created"})
    refute_receive {:parlora_event, %Event{type: :ready}}, 10
    state = ready(context, state)
    assert state.status == :ready
    assert_receive {:parlora_event, %Event{type: :ready}}
    assert {:reply, {:ok, caps}, _} = Grok.handle_call(:capabilities, nil, state)
    assert caps.full_duplex?
    refute inspect(Grok.format_status(%{state: state})) =~ "private-test"
  end

  test "result continuation waits for old generation and queued audio, not backend execution",
       context do
    state = ready(context)
    state = deliver(context, state, created("r1"))
    state = deliver(context, state, audio("r1", <<0::size(960 * 8)>>))
    state = deliver(context, state, call("call", "order 123"))
    assert_receive {:parlora_event, %Event{type: :delegation_requested, payload: %{id: "call"}}}
    {:reply, :ok, state} = Grok.handle_call({:append, update("answer", "call")}, nil, state)

    assert_receive {:grok_command,
                    %{
                      "type" => "conversation.item.create",
                      "event_id" => "answer",
                      "item" => %{"call_id" => "call"}
                    }}

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_submitted,
                      command_id: "answer",
                      payload: %{outcome: :unconfirmed}
                    }}

    refute_receive {:grok_command, %{"type" => "response.create"}}, 10
    state = deliver(context, state, done("r1"))
    refute_receive {:grok_command, %{"type" => "response.create"}}, 10
    assert {:reply, {:ok, [_frame | _rest]}, state} = Grok.handle_call({:read, 960}, nil, state)
    assert_receive {:grok_command, %{"type" => "response.create"}}
    assert state.response == :requested
    {:reply, :ok, _state} = Grok.handle_call({:append, update("answer", "call")}, nil, state)
    refute_receive {:grok_command, _}, 10
  end

  test "interruptions discard old response audio and hold fresh output until matching clear",
       context do
    state = context |> ready() |> then(&deliver(context, &1, created("old")))
    state = deliver(context, state, audio("old", <<0::size(960 * 8)>>))
    state = deliver(context, state, %{"type" => "input_audio_buffer.speech_started"})
    assert_receive {:parlora_event, %Event{type: :output_interrupted, payload: %{token: 1}}}
    assert state.inbound.bytes == 0
    state = deliver(context, state, audio("old", <<0::size(960 * 8)>>))
    assert state.inbound.bytes == 0
    state = deliver(context, state, created("fresh"))
    state = deliver(context, state, audio("fresh", :binary.copy(<<1, 2>>, 480)))
    assert {:reply, {:ok, []}, ^state} = Grok.handle_call({:read, 960}, nil, state)
    assert {:reply, :ok, ^state} = Grok.handle_call({:resume_output, 0}, nil, state)
    {:reply, :ok, state} = Grok.handle_call({:resume_output, 1}, nil, state)
    assert {:reply, {:ok, [frame | _]}, _} = Grok.handle_call({:read, 960}, nil, state)
    assert frame.data != <<0::size(480 * 8)>>

    {:noreply, state} =
      Grok.handle_info({:grok_interruption_timeout, 1}, %{state | output_blocked: true})

    assert state.status == :closed
  end

  test "mute drops queued microphone data and large valid frames are paced", context do
    state = ready(context)
    init = %{state.init | limits: %{state.init.limits | max_frame_bytes: 1_920}}
    state = %{state | init: init}
    frame = AudioFrame.new(:binary.copy(<<1, 2>>, 960), init.audio_format, "input", 0)
    {:reply, :ok, state} = Grok.handle_call({:write, frame}, nil, state)
    {:noreply, state} = Grok.handle_info(:grok_audio_tick, state)
    assert state.outbound.bytes == 960
    assert_receive {:grok_command, %{"type" => "input_audio_buffer.append", "audio" => encoded}}
    assert Base.decode64!(encoded) == :binary.copy(<<1, 2>>, 480)
    {:reply, :ok, state} = Grok.handle_call({:control, "mute", {:input_muted, true}}, nil, state)
    assert state.outbound.bytes == 0

    assert_receive {:parlora_event,
                    %Event{
                      type: :control_completed,
                      command_id: "mute",
                      payload: %{scope: :local_input_gate}
                    }}

    {:noreply, _state} = Grok.handle_info(:grok_audio_tick, state)
    assert_receive {:grok_command, %{"type" => "input_audio_buffer.append", "audio" => silent}}
    assert Base.decode64!(silent) == :binary.copy(<<0>>, 960)
  end

  test "a result arriving during caller speech waits for the automatic VAD response", context do
    state = ready(context)
    state = deliver(context, state, %{"type" => "input_audio_buffer.speech_started"})
    {:reply, :ok, state} = Grok.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Grok.handle_call({:append, update("during-speech", nil)}, nil, state)
    assert_receive {:grok_command, %{"type" => "conversation.item.create"}}
    state = deliver(context, state, %{"type" => "input_audio_buffer.speech_stopped"})
    refute_receive {:grok_command, %{"type" => "response.create"}}, 10
    assert state.auto_response_pending
    state = deliver(context, state, created("vad"))
    refute state.auto_response_pending
    state = deliver(context, state, done("vad"))
    assert state.response == :requested
    assert_receive {:grok_command, %{"type" => "response.create"}}
  end

  test "associated and superseded calls close without duplicate speech or late results",
       context do
    state = ready(context)
    state = deliver(context, state, call("obsolete", "order 123"))

    {:reply, :ok, state} =
      Grok.handle_call({:resolve_delegation, "obsolete", %{status: :superseded}}, nil, state)

    assert_receive {:grok_command, %{"item" => %{"output" => "{\"status\":\"superseded\"}"}}}
    refute_receive {:grok_command, %{"type" => "response.create"}}, 10

    assert {:reply, {:error, _}, state} =
             Grok.handle_call({:append, update("late", "obsolete")}, nil, state)

    state = deliver(context, state, call("duplicate", "order 124"))
    state = deliver(context, state, call("duplicate", "order 124"))

    assert_receive {:parlora_event,
                    %Event{type: :delegation_requested, payload: %{id: "duplicate"}}}

    refute_receive {:parlora_event,
                    %Event{type: :delegation_requested, payload: %{id: "duplicate"}}},
                   10

    {:reply, :ok, state} =
      Grok.handle_call({:resolve_delegation, "duplicate", %{status: :associated}}, nil, state)

    assert state.status == :ready
  end

  test "generated audio overflow, stale reads, and startup failures close explicitly", context do
    state = ready(context)
    overflow = deliver(context, state, audio("r", :binary.copy(<<0>>, 33_602)))
    assert overflow.status == :closed
    assert_receive {:parlora_event, %Event{type: :failed}}
    assert_receive {:parlora_event, %Event{type: :closed, payload: %{finalized?: false}}}
    assert {:noreply, closed} = Grok.handle_info(:grok_startup_timeout, context.state)
    assert closed.key == nil
  end

  test "stale generated audio and missing continuation acknowledgment have finite deadlines",
       context do
    state = ready(context)
    buffered = deliver(context, state, audio("buffered", :binary.copy(<<0>>, 960)))
    {{:value, frame}, rest} = :queue.out(buffered.inbound.items)
    expired = %{frame | timestamp_us: System.monotonic_time(:microsecond) - 800_000}
    stale = %{buffered | inbound: %{buffered.inbound | items: :queue.in_r(expired, rest)}}

    assert {:reply, {:error, %{code: :output_stale}}, closed} =
             Grok.handle_call({:read, 960}, nil, stale)

    assert closed.status == :closed

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{cause: :output_stale}}}

    token = make_ref()
    timer = Process.send_after(self(), :unused, 10_000)

    requested = %{
      context.state
      | status: :ready,
        response: :requested,
        request_timer: {token, timer}
    }

    assert {:noreply, ^requested} =
             Grok.handle_info({:grok_response_timeout, make_ref()}, requested)

    assert {:noreply, closed} = Grok.handle_info({:grok_response_timeout, token}, requested)
    assert closed.status == :closed and closed.request_timer == nil
  end

  test "independent results continue while another response's backend call remains pending",
       context do
    state = ready(context)

    state =
      deliver(context, state, Map.put(call("slow", "order 123"), "response_id", "slow-turn"))

    state =
      deliver(context, state, Map.put(call("fast", "order 124"), "response_id", "fast-turn"))

    {:reply, :ok, state} = Grok.handle_call({:append, update("fast-result", "fast")}, nil, state)
    assert state.calls.records["slow"].status == :pending
    assert state.response == :requested
    assert_receive {:grok_command, %{"type" => "response.create"}}
  end

  test "parallel calls in one response receive all outputs before a single continuation",
       context do
    state = ready(context)
    state = deliver(context, state, Map.put(call("one", "order 123"), "response_id", "parallel"))
    state = deliver(context, state, Map.put(call("two", "order 124"), "response_id", "parallel"))
    {:reply, :ok, state} = Grok.handle_call({:append, update("one-result", "one")}, nil, state)
    refute_receive {:grok_command, %{"type" => "response.create"}}, 10
    {:reply, :ok, state} = Grok.handle_call({:append, update("two-result", "two")}, nil, state)
    assert state.response == :requested
    assert_receive {:grok_command, %{"type" => "response.create"}}
    refute_receive {:grok_command, %{"type" => "response.create"}}, 10
  end

  test "pending continuation timer survives caller interruption and closes a healthy listening turn", context do
    state = ready(context)
    state = deliver(context, state, call("finished-call", "order 124"))
    {:reply, :ok, state} = Grok.handle_call({:append, update("corrected-result", "finished-call")}, nil, state)
    assert state.response == :requested
    {token, _timer} = state.request_timer
    state = deliver(context, state, %{"type" => "input_audio_buffer.speech_started"})
    {:reply, :ok, state} = Grok.handle_call({:resume_output, state.interruption}, nil, state)
    assert state.caller_speaking and state.auto_response_pending
    assert state.request_timer != nil and state.response == :requested
    {:noreply, closed} = Grok.handle_info({:grok_response_timeout, token}, state)
    assert closed.status == :closed
    assert_receive {:parlora_event, %Event{type: :failed, payload: %{error: %{details: %{reason: :response_timeout}}}}}
    IO.puts(Jason.encode!(%{probe: "interrupted_pending_continuation", response_before_timeout: state.response,
      caller_speaking: state.caller_speaking, automatic_turn_pending: state.auto_response_pending,
      continuation_timer_survives: true, outcome: closed.status, reason: :response_timeout}))
  end

  test "late old response during caller speech consumes the correction flag and accepts old audio", context do
    state = ready(context)
    state = deliver(context, state, call("finished-call", "order 123"))
    {:reply, :ok, state} = Grok.handle_call({:append, update("old-result", "finished-call")}, nil, state)
    assert state.response == :requested
    state = deliver(context, state, %{"type" => "input_audio_buffer.speech_started"})
    {:reply, :ok, state} = Grok.handle_call({:resume_output, state.interruption}, nil, state)
    state = deliver(context, state, created("late-old-response"))
    assert state.caller_speaking
    refute state.auto_response_pending
    refute MapSet.member?(state.discarded, "late-old-response")
    state = deliver(context, state, audio("late-old-response", <<0::size(960 * 8)>>))
    assert state.inbound.bytes == 960
    IO.puts(Jason.encode!(%{probe: "late_old_response_during_correction", caller_speaking: state.caller_speaking,
      automatic_turn_pending: state.auto_response_pending, obsolete_audio_accepted_bytes: state.inbound.bytes}))
  end

  defp ready(context, state \\ nil),
    do: deliver(context, state || context.state, %{"type" => "session.updated"})

  defp created(id), do: %{"type" => "response.created", "response" => %{"id" => id}}

  defp done(id),
    do: %{"type" => "response.done", "response" => %{"id" => id, "status" => "completed"}}

  defp audio(id, bytes),
    do: %{
      "type" => "response.output_audio.delta",
      "response_id" => id,
      "delta" => Base.encode64(bytes)
    }

  defp call(id, request),
    do: %{
      "type" => "response.function_call_arguments.done",
      "call_id" => id,
      "name" => Protocol.function(),
      "arguments" => Jason.encode!(%{request: request})
    }

  defp update(id, call),
    do: %ContextUpdate{
      id: id,
      kind: :speakable,
      content: "Verified result",
      delegation_id: call,
      provider_generation: 0
    }

  defp deliver(context, state, event) do
    send(context.server, {:grok_event, event})
    socket = Mint.HTTP.get_socket(state.socket.conn)
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    {:noreply, next} = Grok.handle_info({:tcp, socket, bytes}, state)
    next
  end
end
