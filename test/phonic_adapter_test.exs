defmodule Parlora.PhonicAdapterTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, ContextUpdate, Event, Limits}
  alias Parlora.Provider.WebSocketConnection
  alias Parlora.Providers.Phonic
  alias Parlora.Providers.Phonic.{Audio, Protocol}
  alias Parlora.TestSupport.TwilioPeer

  alias Parlora.TestSupport.PhonicPeer

  setup do
    listener =
      start_supervised!({Bandit, plug: {PhonicPeer.Route, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {:ok, peer} = TwilioPeer.connect_headers(port, Protocol.path(), [])
    assert_receive {:phonic_peer, server}

    init = %AdapterInit{
      session_id: "phonic-test",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, config} = Protocol.start([api_key: "private-test"], init.audio_format)
    {:ok, state, _continue} = Phonic.init({init, [api_key: "private-test"], config})

    state = %{
      state
      | socket: %{conn: peer.conn, ref: peer.ref, ws: peer.websocket, status: 101, headers: []},
        status: :starting
    }

    on_exit(fn -> Phonic.terminate(:normal, state) end)
    %{state: state, server: server}
  end

  test "startup waits for accepted configuration and exposes only effective capabilities",
       context do
    assert {:reply, {:error, %{code: :not_ready}}, _} =
             Phonic.handle_call(:capabilities, nil, context.state)

    state =
      deliver(context, context.state, %{
        "type" => "conversation_created",
        "conversation_id" => "conv-test"
      })

    refute_receive {:parlora_event, %Event{type: :ready}}, 10
    state = ready(context, state)
    assert state.status == :ready and state.conversation_id == "conv-test"
    assert_receive {:parlora_event, %Event{type: :ready}}
    assert {:reply, {:ok, caps}, _} = Phonic.handle_call(:capabilities, nil, state)
    assert caps.full_duplex?
    refute caps.context_acknowledgment? or caps.usage?
    refute inspect(Phonic.format_status(%{state: state})) =~ "private-test"

    assert {:noreply, %{status: :closed, key: nil}} =
             Phonic.handle_info(:phonic_startup_timeout, context.state)
  end

  test "word fragments retain separators and assistant captions share an utterance identity",
       context do
    state = ready(context)
    state = deliver(context, state, %{"type" => "input_text", "text" => "order"})
    state = deliver(context, state, %{"type" => "input_text", "text" => "124"})

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{speaker: :user, delta: "order "}}}

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{speaker: :user, delta: "124 "}}}

    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "Verified "))
    state = deliver(context, state, audio(:binary.copy(<<2, 0>>, 240), "result."))

    assert_receive {:parlora_event,
                    %Event{
                      type: :transcript_delta,
                      payload: %{segment_id: segment, delta: "Verified "}
                    }}

    assert_receive {:parlora_event,
                    %Event{
                      type: :transcript_delta,
                      payload: %{segment_id: ^segment, delta: "result."}
                    }}

    assert {:reply, {:ok, frames}, _} = Phonic.handle_call({:read, 960}, nil, state)

    assert Enum.map(frames, & &1.data) |> IO.iodata_to_binary() ==
             :binary.copy(<<1, 0>>, 240) <> :binary.copy(<<2, 0>>, 240)
  end

  test "continuous idle audio is discarded and PCM speech remains byte exact", context do
    bytes = :binary.copy(<<1, 0>>, 240)
    state = ready(context)
    state = deliver(context, state, audio(bytes, ""))
    assert state.inbound.bytes == 0
    state = deliver(context, state, started())
    state = deliver(context, state, audio(bytes, "result"))
    assert {:reply, {:ok, frames}, _} = Phonic.handle_call({:read, 960}, nil, state)
    assert Enum.map_join(frames, & &1.data) == bytes
  end

  test "plain context is unconfirmed and speakable continuation waits for generation and audio drain",
       context do
    state = ready(context)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("quiet", nil, :quiet)}, nil, state)
    assert_receive {:phonic_command, %{"type" => "add_system_message"}}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_submitted,
                      command_id: "quiet",
                      payload: %{outcome: :unconfirmed}
                    }}

    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 480), "old"))
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", nil)}, nil, state)
    refute_receive {:phonic_command, %{"type" => "add_system_message"}}, 10
    state = deliver(context, state, finished())
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    {:reply, {:ok, _frames}, state} = Phonic.handle_call({:read, 960}, nil, state)
    assert_receive {:phonic_command, %{"type" => "add_system_message"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    assert state.response_watch != nil
    {:reply, :ok, _} = Phonic.handle_call({:append, update("result", nil)}, nil, state)
    refute_receive {:phonic_command, %{"type" => "add_system_message"}}, 10
  end

  test "processed tool output acknowledges its exact command without asserting playback",
       context do
    state = ready(context)
    state = deliver(context, state, call("call", "order 123"))
    state = deliver(context, state, call("call", "order 123"))
    assert_receive {:parlora_event, %Event{type: :delegation_requested, payload: %{id: "call"}}}
    refute_receive {:parlora_event, %Event{type: :delegation_requested}}, 10
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "call")}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "call"}}
    assert map_size(state.tool_timers) == 0
    token = state.acknowledgments["call"].token

    state =
      deliver(context, state, %{"type" => "tool_call_output_processed", "tool_call_id" => "other"})

    refute_receive {:parlora_event, %Event{type: :context_acknowledged}}, 10

    state =
      deliver(context, state, %{"type" => "tool_call_output_processed", "tool_call_id" => "call"})

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_acknowledged,
                      command_id: "result",
                      payload: %{acceptance: :provider_processed}
                    }}

    assert {:noreply, ^state} = Phonic.handle_info({:phonic_ack_timeout, "call", token}, state)
    refute_receive {:parlora_event, %Event{type: :playback_observed}}, 10
  end

  @tag :reply_coordination
  test "caller-time results stay private until the automatic acknowledgment ends, then reply once",
       context do
    state = ready(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", nil)}, nil, state)
    refute_receive {:phonic_command, %{"type" => "add_system_message"}}, 20
    refute_receive {:parlora_event, %Event{type: :context_submitted, command_id: "result"}}, 10
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 480), "Let me check."))
    state = deliver(context, state, finished())
    refute_receive {:phonic_command, %{"type" => "add_system_message"}}, 10
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)

    assert_receive {:phonic_command,
                    %{"type" => "add_system_message", "system_message" => "Verified result"}}

    assert_receive {:phonic_command, %{"type" => "generate_reply", "system_message" => prompt}}
    assert prompt =~ "Verified result"
    state = deliver(context, state, started())
    # Wording is irrelevant to scheduling; no summary/caption matching is used.
    state =
      deliver(
        context,
        state,
        audio(:binary.copy(<<2, 0>>, 480), "Here is your answer, paraphrased.")
      )

    state = deliver(context, state, finished())
    {:reply, {:ok, _}, _state} = Phonic.handle_call({:read, 960}, nil, state)
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 30
  end

  @tag :reply_coordination
  test "a completed association during the owned result reply closes quietly without another announcement",
       context do
    state = ready(context)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", nil)}, nil, state)
    assert_receive {:phonic_command, %{"type" => "add_system_message"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 480), "The verified answer."))
    state = deliver(context, state, call("late", "same request"))

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :unconfirmed,
      result: "Verified result"
    }

    {:reply, :ok, state} = Phonic.handle_call({:resolve_delegation, "late", outcome}, nil, state)
    state = deliver(context, state, finished())
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "late"}}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 30
    assert state.pending_contexts == []
  end

  @tag :reply_coordination
  test "a newer queued revision replaces obsolete facts before either becomes model context",
       context do
    state = ready(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    old = %{update("old", nil) | task_id: "task", task_revision: 1, content: "Obsolete order 123"}
    current = %{old | id: "current", task_revision: 2, content: "Current order 124"}
    {:reply, :ok, state} = Phonic.handle_call({:append, old}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, current}, nil, state)
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: "old"}}
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    _state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})

    assert_receive {:phonic_command,
                    %{"type" => "add_system_message", "system_message" => "Current order 124"}}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    refute_receive {:phonic_command, %{"system_message" => "Obsolete order 123"}}, 30
  end

  @tag :reply_coordination
  test "a cancelled queued tool result never reaches context or requests speech", context do
    state = ready(context)
    state = deliver(context, state, call("cancel", "order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "cancel")}, nil, state)

    state =
      deliver(context, state, %{"type" => "tool_call_interrupted", "tool_call_id" => "cancel"})

    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: "result"}}
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    _state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 20
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 20
  end

  @tag :reply_coordination
  test "early tool turns release queued results on caller end without waiting for forbidden speech",
       context do
    {:ok, config} =
      Protocol.start(
        [api_key: "private-test", early_delegation: true],
        context.state.init.audio_format
      )

    assert hd(config.tools).can_run_during_user_speech
    state = ready(context, %{context.state | config: config})
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    state = deliver(context, state, call("early", "order"))
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "early")}, nil, state)
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    _state = deliver(context, state, %{"type" => "user_finished_speaking"})
    assert_receive {:phonic_command, %{"type" => "tool_call_output"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
  end

  @tag :reply_coordination
  test "an empty started reply yielding to a tool resumes without a speech-end event", context do
    state = ready(context)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", nil)}, nil, state)
    assert_receive {:phonic_command, %{"type" => "add_system_message"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    state = deliver(context, state, started())
    state = deliver(context, state, call("yielded", "get current result"))
    assert state.speech == :idle

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :accepted,
      result: "Verified result"
    }

    {:reply, :ok, state} =
      Phonic.handle_call({:resolve_delegation, "yielded", outcome}, nil, state)

    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "yielded"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    state = deliver(context, state, started())
    state = deliver(context, state, audio(<<>>, "Current verified answer."))
    _state = deliver(context, state, finished())
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 20
  end

  test "a completed late association resumes after a reply consumed the original continuation",
       context do
    state = ready(context)
    state = deliver(context, state, call("original", "order 123"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)

    {:reply, :ok, state} =
      Phonic.handle_call({:append, update("corrected", "original")}, nil, state)

    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    state = deliver(context, state, call("corrected-call", "order 124"))
    state = deliver(context, state, started())
    state = deliver(context, state, finished())
    assert_receive {:phonic_command, %{"type" => "tool_call_output"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    state = deliver(context, state, call("late", "get the result"))
    state = deliver(context, state, started())
    state = deliver(context, state, finished())
    refute state.continuation?

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :accepted,
      result: "Verified result"
    }

    {:reply, :ok, state} = Phonic.handle_call({:resolve_delegation, "late", outcome}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "late"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    state = deliver(context, state, started())
    state = deliver(context, state, finished())

    {:reply, :ok, state} =
      Phonic.handle_call({:resolve_delegation, "corrected-call", outcome}, nil, state)

    assert_receive {:phonic_command, %{"type" => "tool_call_output"}}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10

    # A fresh caller turn may explicitly ask for the same result again.
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 2}, nil, state)
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    state = deliver(context, state, started())
    state = deliver(context, state, finished())
    state = deliver(context, state, call("repeat", "order 124 again"))
    {:reply, :ok, _} = Phonic.handle_call({:resolve_delegation, "repeat", outcome}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
  end

  test "interruption events in either order clear once and retain fresh speech behind the clear barrier",
       context do
    for events <- [
          [%{"type" => "interrupted_response"}, %{"type" => "user_started_speaking"}],
          [%{"type" => "user_started_speaking"}, %{"type" => "interrupted_response"}]
        ] do
      state = ready(context)
      state = deliver(context, state, started())
      state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 480), "old"))
      state = Enum.reduce(events, state, &deliver(context, &2, &1))
      assert state.inbound.bytes == 0 and state.interruption == 1 and state.output_blocked
      assert_receive {:parlora_event, %Event{type: :output_interrupted, payload: %{token: 1}}}
      refute_receive {:parlora_event, %Event{type: :output_interrupted}}, 10
      state = deliver(context, state, audio(:binary.copy(<<2, 0>>, 480), "late old"))
      assert state.inbound.bytes == 0
      state = deliver(context, state, %{"type" => "user_finished_speaking"})
      state = deliver(context, state, started())
      state = deliver(context, state, audio(:binary.copy(<<3, 0>>, 480), "fresh"))
      {:reply, :ok, unchanged} = Phonic.handle_call({:resume_output, 0}, nil, state)
      assert unchanged.output_blocked
      assert {:reply, {:ok, []}, _} = Phonic.handle_call({:read, 960}, nil, unchanged)
      {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
      assert {:reply, {:ok, frames}, _} = Phonic.handle_call({:read, 960}, nil, state)
      assert Enum.map_join(frames, & &1.data) == :binary.copy(<<3, 0>>, 480)
    end
  end

  test "late associations do not announce pending work or undeliverable results", context do
    state = ready(context)

    for {id, status, delivery} <- [
          {"pending", :running, nil},
          {"undelivered", :completed, :pending},
          {"no-summary", :completed, :not_applicable},
          {"obsolete", :completed, :stale}
        ] do
      state = deliver(context, state, call(id, "order"))

      outcome = %{
        status: :associated,
        task_status: status,
        result_delivery: delivery,
        result: "This request is already tracked."
      }

      {:reply, :ok, state} = Phonic.handle_call({:resolve_delegation, id, outcome}, nil, state)
      assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => ^id}}
      refute state.continuation?
      refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    end
  end

  test "a tool-only automatic turn releases the speech wait for a completed result", context do
    state = ready(context)
    state = deliver(context, state, call("original", "order 123"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)

    {:reply, :ok, state} =
      Phonic.handle_call({:append, update("corrected", "original")}, nil, state)

    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    old_watch = state.response_watch.token
    state = deliver(context, state, call("corrected-call", "order 124"))
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :accepted,
      result: "Verified result"
    }

    {:reply, :ok, state} =
      Phonic.handle_call({:resolve_delegation, "corrected-call", outcome}, nil, state)

    assert_receive {:phonic_command, %{"type" => "tool_call_output"}}
    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    assert {:noreply, ^state} = Phonic.handle_info({:phonic_response_timeout, old_watch}, state)
  end

  test "results during caller speech wait for the automatic turn and a missing turn has a deadline",
       context do
    state = ready(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("during-speech", nil)}, nil, state)
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    token = state.response_watch.token
    assert {:noreply, ^state} = Phonic.handle_info({:phonic_response_timeout, make_ref()}, state)

    assert {:noreply, %{status: :closed}} =
             Phonic.handle_info({:phonic_response_timeout, token}, state)
  end

  test "queued tool expiry falls back to current context without replaying an expired output",
       context do
    state = ready(context)
    state = deliver(context, state, call("expire", "order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "expire")}, nil, state)
    token = state.tool_timers["expire"].token
    {:noreply, state} = Phonic.handle_info({:phonic_tool_timeout, "expire", token}, state)
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    _state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})

    assert_receive {:phonic_command,
                    %{"type" => "add_system_message", "system_message" => "Verified result"}}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 20
  end

  test "pending context capacity and close have explicit outcomes for admitted commands",
       context do
    state = ready(context)
    state = %{state | init: %{state.init | limits: %{state.init.limits | max_records: 1}}}
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("first", nil)}, nil, state)

    {:reply, {:error, %{code: :backpressure}}, state} =
      Phonic.handle_call({:append, update("second", nil)}, nil, state)

    {:reply, :ok, closed} = Phonic.handle_call({:close, "close", :cancel}, nil, state)
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: "first"}}
    refute_receive {:parlora_event, %Event{type: :context_submitted}}, 20
    assert closed.pending_contexts == []
  end

  test "acknowledgment timeout is uncertain, and provider cancellation suppresses late correlated results",
       context do
    state = ready(context)
    state = deliver(context, state, call("one", "order 123"))
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result-one", "one")}, nil, state)
    token = state.acknowledgments["one"].token
    {:noreply, state} = Phonic.handle_info({:phonic_ack_timeout, "one", token}, state)

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_rejected,
                      command_id: "result-one",
                      payload: %{outcome: :unknown}
                    }}

    state =
      deliver(context, state, %{"type" => "tool_call_output_processed", "tool_call_id" => "one"})

    refute_receive {:parlora_event, %Event{type: :context_acknowledged}}, 10
    state = deliver(context, state, call("two", "order 124"))
    state = deliver(context, state, %{"type" => "tool_call_interrupted", "tool_call_id" => "two"})
    assert_receive {:parlora_event, %Event{type: :delegation_cancelled, payload: %{id: "two"}}}

    assert {:reply, {:error, _}, _} =
             Phonic.handle_call({:append, update("late", "two")}, nil, state)
  end

  test "an expired tool can receive a current result as new context without resending its old output",
       context do
    state = ready(context)
    state = deliver(context, state, call("expire", "order"))
    token = state.tool_timers["expire"].token
    {:noreply, state} = Phonic.handle_info({:phonic_tool_timeout, "expire", token}, state)

    {:reply, :ok, state} =
      Phonic.handle_call({:append, update("late-current", "expire")}, nil, state)

    assert_receive {:phonic_command, %{"type" => "add_system_message"}}
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    assert state.calls.records["expire"].status == :expired
  end

  test "malformed acknowledgment cannot turn an unconfirmed result into success", context do
    state = ready(context)
    state = deliver(context, state, call("call", "order 123"))
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "call")}, nil, state)

    state =
      deliver(context, state, %{
        "type" => "tool_call_output_processed",
        "tool_call_id" => "call",
        "timed_out" => "false"
      })

    assert state.status == :closed
    refute_receive {:parlora_event, %Event{type: :context_acknowledged}}, 10

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_rejected,
                      command_id: "result",
                      payload: %{outcome: :unknown}
                    }}
  end

  test "stale generated speech fails explicitly instead of being served after its age limit",
       context do
    state = ready(context)
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 480), "stale"))
    {{:value, frame}, rest} = :queue.out(state.inbound.items)
    old = %{frame | timestamp_us: System.monotonic_time(:microsecond) - 800_000}
    state = %{state | inbound: %{state.inbound | items: :queue.in_r(old, rest)}}

    assert {:reply, {:error, %{code: :output_stale}}, closed} =
             Phonic.handle_call({:read, 960}, nil, state)

    assert closed.status == :closed
  end

  test "missing channel clear cannot retain blocked speech indefinitely", context do
    state = ready(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    assert {:noreply, ^state} = Phonic.handle_info({:phonic_interruption_timeout, 0}, state)

    assert {:noreply, %{status: :closed}} =
             Phonic.handle_info({:phonic_interruption_timeout, 1}, state)
  end

  test "malformed PCM is rejected even when the pipeline format is mu-law", context do
    converter = Audio.new(AudioFormat.pcmu())
    on_exit(fn -> Audio.close(converter) end)
    state = ready(context)
    state = %{state | init: %{state.init | audio_format: AudioFormat.pcmu()}, audio: converter}
    state = deliver(context, state, started())
    state = deliver(context, state, audio(<<1, 2, 3>>, "invalid"))
    assert state.status == :closed and state.audio == nil
  end

  test "input mute sends silence and frame pacing remains within the provider's 40 ms limit",
       context do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      state = ready(context)
      converter = Audio.new(format)
      on_exit(fn -> Audio.close(converter) end)
      state = %{state | init: %{state.init | audio_format: format}, audio: converter}
      bytes = AudioFormat.bytes_for_ms(format, 40)

      state = %{
        state
        | init: %{state.init | limits: %{state.init.limits | max_frame_bytes: bytes}}
      }

      data = :binary.copy(<<123>>, bytes)
      frame = AudioFrame.new(data, format, "microphone", 0)
      {:reply, :ok, state} = Phonic.handle_call({:write, frame}, nil, state)
      {:noreply, state} = Phonic.handle_info(:phonic_audio_tick, state)
      assert_receive {:phonic_command, %{"type" => "audio_chunk", "audio" => encoded}}
      transmitted = Base.decode64!(encoded)
      assert byte_size(transmitted) in 940..960
      if format.codec == :pcm, do: assert(transmitted == binary_part(data, 0, 960))

      {:reply, :ok, state} =
        Phonic.handle_call({:control, "mute", {:input_muted, true}}, nil, state)

      {:reply, :ok, state} = Phonic.handle_call({:write, frame}, nil, state)
      {:noreply, state} = Phonic.handle_info(:phonic_audio_tick, state)
      assert_receive {:phonic_command, %{"type" => "audio_chunk", "audio" => encoded}}
      silence = Base.decode64!(encoded)
      assert byte_size(silence) in 940..960
      assert silence == :binary.copy(<<0>>, byte_size(silence))
      assert state.outbound.bytes == 0
    end
  end

  for event <- [
        %{"type" => "error", "error" => "private-test"},
        %{
          "type" => "error",
          "error" => %{"code" => "data_retention_not_allowed", "message" => "private-test"}
        }
      ] do
    @provider_error event
    test "provider rejection #{inspect(event)} never leaks raw provider data", context do
      state = deliver(context, context.state, @provider_error)
      assert state.status == :closed and state.key == nil and state.config == nil
      assert_receive {:parlora_event, %Event{type: :failed, payload: %{error: error}}}
      refute inspect(error) =~ "private-test"
    end
  end

  for {name, bytes} <- [truncated: ~s({"private":), invalid_unicode: ~S({"private":"\uD800"})] do
    @malformed bytes
    test "fragmented #{name} JSON closes without decoder contents", context do
      send(context.server, {:raw_json, @malformed})
      state = receive_event(context.state, System.monotonic_time(:millisecond) + 2_000, 1)
      assert state.status == :closed

      assert_receive {:parlora_event,
                      %Event{
                        type: :failed,
                        payload: %{error: %{details: %{reason: :invalid_json}}}
                      }}
    end
  end

  test "buffer overflow and disconnect have explicit bounded outcomes, never transparent replay",
       context do
    state = ready(context)
    state = deliver(context, state, started())
    closed = deliver(context, state, audio(:binary.copy(<<1, 0>>, 16_801), "overflow"), 1)
    assert closed.status == :closed and closed.key == nil

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{cause: :output_overflow}}}

    assert_receive {:parlora_event, %Event{type: :closed, payload: %{finalized?: false}}}
  end

  defp ready(context, state \\ nil),
    do: deliver(context, state || context.state, %{"type" => "ready_to_start_conversation"})

  defp started, do: %{"type" => "assistant_started_speaking"}
  defp finished, do: %{"type" => "assistant_finished_speaking"}

  defp audio(bytes, text),
    do: %{"type" => "audio_chunk", "audio" => Base.encode64(bytes), "text" => text}

  defp call(id, request),
    do: %{
      "type" => "tool_call",
      "tool_call_id" => id,
      "tool_name" => Protocol.function(),
      "parameters" => %{"request" => request}
    }

  defp update(id, call, kind \\ :speakable),
    do: %ContextUpdate{
      id: id,
      kind: kind,
      content: "Verified result",
      delegation_id: call,
      provider_generation: 0
    }

  defp deliver(context, state, event, first_read_bytes \\ 0) do
    send(context.server, {:phonic_event, event})
    receive_event(state, System.monotonic_time(:millisecond) + 2_000, first_read_bytes)
  end

  defp receive_event(state, deadline, read_bytes) do
    socket = Mint.HTTP.get_socket(state.socket.conn)
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "Phonic fixture did not receive a complete WebSocket frame"
    assert {:ok, bytes} = :gen_tcp.recv(socket, read_bytes, remaining)
    message = {:tcp, socket, bytes}
    {:ok, _socket, frames} = WebSocketConnection.receive(state.socket, message)
    {:noreply, next} = Phonic.handle_info(message, state)
    if frames == [], do: receive_event(next, deadline, 0), else: next
  end
end
