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

    {:ok, config} =
      Protocol.start([api_key: "private-test", wait_for_response: false], init.audio_format)

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

  @tag :non_speech_transcript
  test "punctuation-only input is observable but never admitted as a caller transcript",
       context do
    state = ready_busy(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})

    for text <- [".", "...", "?! —", "…", "♫"] do
      _state = deliver(context, state, %{"type" => "input_text", "text" => text})

      refute_receive {:parlora_event,
                      %Event{type: :transcript_delta, payload: %{speaker: :user}}},
                     10

      assert_receive {:parlora_event,
                      %Event{
                        type: :extension,
                        payload: %{
                          kind: :transcript_discarded,
                          cause: :no_lexical_content,
                          delta: ^text
                        }
                      }}
    end
  end

  test "single-word refusals, non-English replies and phone digits remain caller speech",
       context do
    state = ready_busy(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})

    for text <- ["No", "Stop", "Sí", "نعم", "はい", "0188", "٠١٨٨"] do
      _state = deliver(context, state, %{"type" => "input_text", "text" => text})
      expected = text <> " "

      assert_receive {:parlora_event,
                      %Event{
                        type: :transcript_delta,
                        payload: %{speaker: :user, delta: ^expected}
                      }}
    end
  end

  @tag :overlapping_native_speech
  test "an acknowledgment ending after the result starts cannot discard the native result",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("original", "Wednesday"))
    result = %{update("current", "original") | content: "Thursday has 10:15 AM or 2 PM."}
    {:reply, :ok, state} = Phonic.handle_call({:append, result}, nil, state)

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    state = deliver(context, state, started())
    state = deliver(context, state, call("alias", "Thursday"))

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :accepted,
      result: result.content
    }

    {:reply, :ok, state} = Phonic.handle_call({:resolve_delegation, "alias", outcome}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "alias"}}

    prefix = :binary.copy(<<1, 0>>, 240)
    verified = :binary.copy(<<2, 0>>, 240)
    state = deliver(context, state, audio(prefix, "Let me check Thursday."))
    state = deliver(context, state, started())
    state = deliver(context, state, finished())
    assert state.speech == :speaking
    assert state.accepting_output?
    state = deliver(context, state, audio(verified, result.content))

    assert_receive {:parlora_event,
                    %Event{
                      type: :transcript_delta,
                      payload: %{delta: "Thursday has 10:15 AM or 2 PM."}
                    }}

    state = deliver(context, state, finished())
    assert state.speech == :idle
    {:reply, {:ok, frames}, _state} = Phonic.handle_call({:read, 960}, nil, state)
    assert Enum.map_join(frames, & &1.data) == prefix <> verified
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  @tag :cancelled_input
  test "cancelled non-speech releases a queued native result without inventing a caller turn",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("original", "propose selected slot"))
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "Let me check."))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    segment = state.caller_segment_id

    assert_receive {:parlora_event,
                    %Event{
                      type: :extension,
                      payload: %{kind: :caller_speech, state: :started, segment_id: ^segment}
                    }}

    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)

    {:reply, :ok, state} =
      Phonic.handle_call({:append, update("proposal", "original")}, nil, state)

    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    state = deliver(context, state, %{"type" => "input_cancelled"})
    refute state.caller_speaking or state.auto_response_pending
    assert state.pending_contexts == []

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    assert_receive {:parlora_event,
                    %Event{
                      type: :extension,
                      payload: %{kind: :caller_speech, state: :cancelled, segment_id: ^segment}
                    }}

    watch = state.response_watch
    assert watch != nil
    state = deliver(context, state, %{"type" => "input_cancelled"})
    assert state.response_watch == watch
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    assert state.response_watch == watch
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10

    refute_receive {:parlora_event, %Event{type: :transcript_delta, payload: %{speaker: :user}}},
                   10
  end

  @tag :cancelled_input
  test "cancelling an automatic input response retires its watchdog and keeps fresh No interruptible",
       context do
    state = ready_busy(context)
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    token = state.response_watch.token
    state = deliver(context, state, %{"type" => "input_cancelled"})
    assert state.response_watch == nil
    assert {:noreply, ^state} = Phonic.handle_info({:phonic_response_timeout, token}, state)
    state = deliver(context, state, started())
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    state = deliver(context, state, %{"type" => "input_text", "text" => "No"})
    assert state.caller_speaking and state.interrupted?
    assert_receive {:parlora_event, %Event{type: :output_interrupted, payload: %{token: 2}}}

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{speaker: :user, delta: "No "}}}
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

  for finish_order <- [:during_caller, :after_caller] do
    @finish_order finish_order
    @tag :reply_coordination
    test "native backchannel ending #{@finish_order} does not release queued facts", context do
      {:ok, config} =
        Protocol.start(
          [api_key: "private-test", enable_assistant_backchannel: true, wait_for_response: false],
          context.state.init.audio_format
        )

      state = ready(context, %{context.state | config: config})
      state = deliver(context, state, %{"type" => "user_started_speaking"})
      {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
      state = deliver(context, state, %{"type" => "input_text", "text" => "Yes"})

      assert_receive {:parlora_event,
                      %Event{
                        type: :transcript_delta,
                        payload: %{speaker: :user, segment_id: caller}
                      }}

      assert is_binary(caller)
      {:reply, :ok, state} = Phonic.handle_call({:append, update("result", nil)}, nil, state)
      state = deliver(context, state, started())
      state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "Mm-hmm."))

      assert_receive {:parlora_event,
                      %Event{
                        type: :transcript_delta,
                        payload: %{speaker: :assistant, overlaps_user_segment_id: ^caller}
                      }}

      state = deliver(context, state, %{"type" => "input_text", "text" => "if it's free"})

      assert_receive {:parlora_event,
                      %Event{
                        type: :transcript_delta,
                        payload: %{speaker: :user, segment_id: ^caller}
                      }}

      state =
        if @finish_order == :during_caller, do: deliver(context, state, finished()), else: state

      assert state.auto_response_pending
      state = deliver(context, state, %{"type" => "user_finished_speaking"})
      watch = state.response_watch
      assert watch != nil and state.auto_response_pending

      state =
        if @finish_order == :after_caller, do: deliver(context, state, finished()), else: state

      assert state.auto_response_pending and state.response_watch == watch
      {:reply, {:ok, frames}, state} = Phonic.handle_call({:read, 960}, nil, state)
      assert Enum.map_join(frames, & &1.data) == :binary.copy(<<1, 0>>, 240)
      refute_receive {:phonic_command, %{"type" => "add_system_message"}}, 10
      refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
      state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})
      refute state.auto_response_pending
      assert_receive {:phonic_command, %{"type" => "add_system_message"}}
      assert_receive {:phonic_command, %{"type" => "generate_reply"}}
      refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    end
  end

  @tag :reply_coordination
  test "native busy mode can ask an application clarification without manually repeating its result",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order 123"))
    state = deliver(context, state, call("busy", "order 123"))
    assert_receive {:parlora_event, %Event{type: :delegation_requested, payload: %{id: "busy"}}}
    refute_receive {:parlora_event, %Event{type: :delegation_requested}}, 10
    question = %{update("question", nil) | content: "Which order color did you want?"}
    {:reply, :ok, state} = Phonic.handle_call({:append, question}, nil, state)

    assert_receive {:phonic_command,
                    %{
                      "type" => "add_system_message",
                      "system_message" => "Which order color did you want?"
                    }}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    assert state.busy_call_id == "busy"
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "busy")}, nil, state)
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "Which color?"))
    state = deliver(context, state, finished())
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)

    assert_receive {:phonic_command,
                    %{
                      "type" => "tool_call_output",
                      "tool_call_id" => "busy",
                      "output" => %{"result" => "Verified result"}
                    }}

    assert state.busy_call_id == nil and state.response_watch != nil
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10

    state =
      deliver(context, state, %{"type" => "tool_call_output_processed", "tool_call_id" => "busy"})

    assert_receive {:parlora_event, %Event{type: :context_acknowledged, command_id: "result"}}
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<2, 0>>, 240), "Verified result."))
    state = deliver(context, state, finished())
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)
    assert state.pending_contexts == []
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "native busy mode replaces an unsent obsolete result on its original call", context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order 123"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)

    old = %{
      update("old", "busy")
      | task_id: "task",
        task_revision: 1,
        content: "Obsolete order 123"
    }

    new = %{old | id: "new", task_revision: 2, content: "Current verified order 124"}
    {:reply, :ok, state} = Phonic.handle_call({:append, old}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, new}, nil, state)
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: "old"}}
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})

    assert_receive {:phonic_command,
                    %{
                      "type" => "tool_call_output",
                      "tool_call_id" => "busy",
                      "output" => %{"result" => "Current verified order 124"}
                    }}

    assert state.calls.records["busy"].outcome == %{result: "Current verified order 124"}
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    {:reply, :ok, _} = Phonic.handle_call({:append, new}, nil, state)
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
  end

  test "a busy caller correction does not wait for an ordinary reply before publishing its tool result",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "check Wednesday"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    state = deliver(context, state, %{"type" => "input_text", "text" => "Thursday instead"})
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    assert state.response_watch == nil and not state.auto_response_pending
    assert state.busy_call_id == "busy"
    {:reply, :ok, state} = Phonic.handle_call({:append, update("corrected", "busy")}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "busy"}}
    assert state.response_watch != nil
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "a pending native association waits for its scoped task result without completing early",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("alias", "same request"))
    metadata = %{task_id: "tracked", task_revision: 1, provider_generation: 0}
    outcome = %{status: :associated, task_status: :submitted, result: "Still pending"}

    {:reply, :ok, state} =
      Phonic.handle_call({:resolve_delegation, "alias", outcome, metadata}, nil, state)

    assert state.calls.records["alias"].status == :pending
    assert state.busy_task == metadata
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    fact = %{update("result", nil) | task_id: "tracked", task_revision: 2}
    quiet = %{fact | id: "quiet", kind: :quiet}
    {:reply, :ok, state} = Phonic.handle_call({:append, quiet}, nil, state)
    assert_receive {:phonic_command, %{"type" => "add_system_message"}}
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    assert state.calls.records["alias"].status == :pending
    {:reply, :ok, state} = Phonic.handle_call({:append, fact}, nil, state)

    assert_receive {:phonic_command,
                    %{
                      "type" => "tool_call_output",
                      "tool_call_id" => "alias",
                      "output" => %{"result" => "Verified result"}
                    }}

    assert state.busy_task == nil
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "native task binding preserves queued context IDs and rejects stale or foreign metadata",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("alias", "same request"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    fact = %{update("result", nil) | task_id: "tracked", task_revision: 2}
    {:reply, :ok, state} = Phonic.handle_call({:append, fact}, nil, state)
    metadata = %{task_id: "tracked", task_revision: 1, provider_generation: 0}

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :awaiting_provider,
      result: "Verified result"
    }

    assert {:reply, {:error, %{code: :invalid_argument}}, _} =
             Phonic.handle_call(
               {:resolve_delegation, "alias", outcome, %{metadata | provider_generation: 9}},
               nil,
               state
             )

    {:reply, :ok, state} =
      Phonic.handle_call({:resolve_delegation, "alias", outcome, metadata}, nil, state)

    assert state.busy_task.task_revision == 2
    stale = %{fact | id: "old", task_revision: 1}

    assert {:reply, {:error, %{code: :invalid_argument}}, _} =
             Phonic.handle_call({:append, stale}, nil, state)

    foreign = %{fact | id: "foreign", task_id: "different", delegation_id: "alias"}

    assert {:reply, {:error, %{code: :invalid_argument}}, _} =
             Phonic.handle_call({:append, foreign}, nil, state)

    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "alias"}}
    assert_receive {:parlora_event, %Event{type: :context_submitted, command_id: "result"}}

    _state =
      deliver(context, state, %{"type" => "tool_call_output_processed", "tool_call_id" => "alias"})

    assert_receive {:parlora_event, %Event{type: :context_acknowledged, command_id: "result"}}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "a queued clarification completes its native call once and a later result uses fresh context",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    question = %{update("question", "busy") | content: "Which order?"}
    {:reply, :ok, state} = Phonic.handle_call({:append, question}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "busy")}, nil, state)
    state = deliver(context, state, %{"type" => "user_finished_speaking"})

    assert_receive {:phonic_command,
                    %{
                      "type" => "tool_call_output",
                      "tool_call_id" => "busy",
                      "output" => %{"result" => "Which order?"}
                    }}

    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "Which order?"))
    state = deliver(context, state, finished())
    {:reply, {:ok, _}, _state} = Phonic.handle_call({:read, 960}, nil, state)

    assert_receive {:phonic_command,
                    %{"type" => "add_system_message", "system_message" => "Verified result"}}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "native busy associations retain facts without manual replies and discourage repetition",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("first", "order"))
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "first")}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "first"}}
    state = deliver(context, state, started())
    state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "The verified result."))
    state = deliver(context, state, finished())
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)
    state = deliver(context, state, call("late", "same order"))

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :unconfirmed,
      result: "Verified result"
    }

    {:reply, :ok, state} = Phonic.handle_call({:resolve_delegation, "late", outcome}, nil, state)
    state = deliver(context, state, finished())
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "late", "output" => output}}

    assert output["result"] == "Verified result"
    assert output["instruction"] =~ "Do not repeat"
    assert state.response_watch != nil
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})
    assert state.pending_contexts == []
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  @tag :native_alias_result
  test "a native alias still receives verified facts after an acknowledgment ended the prior reply",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("original", "check Wednesday"))
    result = %{update("corrected", "original") | content: "Thursday has 10:15 AM and 2 PM."}
    {:reply, :ok, state} = Phonic.handle_call({:append, result}, nil, state)

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    state = deliver(context, state, started())

    state =
      deliver(context, state, audio(:binary.copy(<<1, 0>>, 240), "Let me switch to Thursday."))

    state = deliver(context, state, finished())
    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)
    state = deliver(context, state, call("alias", "check Thursday"))
    refute state.calls.records["alias"][:reply_yielded?]

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :accepted,
      result: result.content
    }

    {:reply, :ok, state} = Phonic.handle_call({:resolve_delegation, "alias", outcome}, nil, state)

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "alias", "output" => output}}

    assert output["result"] == result.content
    assert output["instruction"] =~ "Do not repeat"
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    assert state.response_watch != nil
  end

  test "native busy cancellation removes queued results and admits a later fresh call", context do
    state = ready_busy(context)
    state = deliver(context, state, call("cancel", "order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "cancel")}, nil, state)

    state =
      deliver(context, state, %{"type" => "tool_call_interrupted", "tool_call_id" => "cancel"})

    assert state.busy_call_id == nil
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: "result"}}
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    state = deliver(context, state, call("fresh", "order 124"))
    assert state.busy_call_id == "fresh"
  end

  test "native busy deadlines fail explicitly without retrying or inventing a tool result",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order"))
    token = state.tool_timers["busy"].token

    assert {:noreply, %{status: :closed}} =
             Phonic.handle_info({:phonic_tool_timeout, "busy", token}, state)

    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
  end

  test "a missing native result response expires without an extra manual reply", context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order"))
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "busy")}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output"}}
    token = state.response_watch.token

    assert {:noreply, %{status: :closed}} =
             Phonic.handle_info({:phonic_response_timeout, token}, state)

    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "provider expiry releases native ownership and later current facts use one fresh manual reply",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "busy")}, nil, state)

    state =
      deliver(context, state, %{
        "type" => "tool_call_output_processed",
        "tool_call_id" => "busy",
        "timed_out" => true
      })

    assert state.busy_call_id == nil and state.response_watch != nil
    state = deliver(context, state, %{"type" => "user_finished_speaking"})
    _state = deliver(context, state, %{"type" => "assistant_chose_not_to_respond"})

    assert_receive {:phonic_command,
                    %{"type" => "add_system_message", "system_message" => "Verified result"}}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  test "replacing a native result still validates its JSON-encoded tool-output budget", context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:append, update("old", "busy")}, nil, state)
    new = %{update("new", "busy") | content: String.duplicate("\"", 8_000)}

    assert {:reply, {:error, %{code: :invalid_argument}}, next} =
             Phonic.handle_call({:append, new}, nil, state)

    assert next.pending_contexts == state.pending_contexts
    assert next.calls == state.calls

    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
  end

  test "native busy mode rejects an unexpected simultaneous tool before delegating it", context do
    state = ready_busy(context)
    state = deliver(context, state, call("first", "order"))
    assert_receive {:parlora_event, %Event{type: :delegation_requested, payload: %{id: "first"}}}
    state = deliver(context, state, call("second", "another order"))
    assert state.status == :closed
    refute_receive {:parlora_event, %Event{type: :delegation_requested}}, 10
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
        [api_key: "private-test", early_delegation: true, wait_for_response: false],
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
      state = deliver(context, state, started())
      assert state.speech_ends_pending == 2
      state = deliver(context, state, audio(:binary.copy(<<1, 0>>, 480), "old"))
      state = Enum.reduce(events, state, &deliver(context, &2, &1))
      assert state.inbound.bytes == 0 and state.interruption == 1 and state.output_blocked
      assert state.speech_ends_pending == 0
      assert_receive {:parlora_event, %Event{type: :output_interrupted, payload: %{token: 1}}}
      refute_receive {:parlora_event, %Event{type: :output_interrupted}}, 10
      state = deliver(context, state, audio(:binary.copy(<<2, 0>>, 480), "late old"))
      assert state.inbound.bytes == 0
      state = deliver(context, state, %{"type" => "user_finished_speaking"})
      state = deliver(context, state, started())
      assert state.speech_ends_pending == 1
      state = deliver(context, state, audio(:binary.copy(<<3, 0>>, 480), "fresh"))
      {:reply, :ok, unchanged} = Phonic.handle_call({:resume_output, 0}, nil, state)
      assert unchanged.output_blocked
      assert {:reply, {:ok, []}, _} = Phonic.handle_call({:read, 960}, nil, unchanged)
      {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
      assert {:reply, {:ok, frames}, _} = Phonic.handle_call({:read, 960}, nil, state)
      assert Enum.map_join(frames, & &1.data) == :binary.copy(<<3, 0>>, 480)
      state = deliver(context, state, finished())
      assert state.speech == :idle and state.speech_ends_pending == 0
    end
  end

  test "unmatched speech starts fail at the configured record bound", context do
    state = ready_busy(context)
    state = %{state | init: %{state.init | limits: %{state.init.limits | max_records: 2}}}
    state = deliver(context, state, started())
    state = deliver(context, state, started())
    assert state.status == :ready and state.speech_ends_pending == 2
    state = deliver(context, state, started())
    assert state.status == :closed and state.speech_ends_pending == 0

    assert_receive {:parlora_event,
                    %Event{
                      type: :failed,
                      payload: %{error: %{details: %{reason: :speech_boundary_overflow}}}
                    }}
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

  test "native task aliases bind replacement and cancellation to their actual wire call",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("original", "order"))

    state =
      deliver(context, state, %{"type" => "tool_call_interrupted", "tool_call_id" => "original"})

    state = deliver(context, state, call("alias", "same task"))
    metadata = %{task_id: "tracked", task_revision: 1, provider_generation: 0}
    outcome = %{status: :associated, task_status: :submitted, result: "Still pending"}

    {:reply, :ok, state} =
      Phonic.handle_call({:resolve_delegation, "alias", outcome, metadata}, nil, state)

    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)

    old = %{
      update("old", "original")
      | task_id: "tracked",
        task_revision: 1,
        content: "Obsolete order"
    }

    current = %{old | id: "current", task_revision: 2, content: "Current verified order"}
    {:reply, :ok, state} = Phonic.handle_call({:append, old}, nil, state)
    {:reply, :ok, state} = Phonic.handle_call({:append, current}, nil, state)
    assert_receive {:parlora_event, %Event{type: :context_rejected, command_id: "old"}}

    state =
      deliver(context, state, %{"type" => "tool_call_interrupted", "tool_call_id" => "original"})

    refute_receive {:parlora_event, %Event{type: :context_rejected, command_id: "current"}}, 10
    assert [%{id: "current"}] = state.pending_contexts
    _state = deliver(context, state, %{"type" => "user_finished_speaking"})

    assert_receive {:phonic_command,
                    %{
                      "type" => "tool_call_output",
                      "tool_call_id" => "alias",
                      "output" => %{"result" => "Current verified order"}
                    }}

    refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10
  end

  for caption <- ["", "Let me check."] do
    @handoff_caption caption
    test "native result handoff after #{inspect(caption)} retires the abandoned generation",
         context do
      state = ready_busy(context)
      state = deliver(context, state, call("first", "order"))
      {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "first")}, nil, state)
      assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "first"}}
      state = deliver(context, state, started())
      state = deliver(context, state, audio(:binary.copy(<<0, 0>>, 240), @handoff_caption))
      state = deliver(context, state, call("alias", "same order"))

      outcome = %{
        status: :associated,
        task_status: :completed,
        result_delivery: :unconfirmed,
        result: "Verified result"
      }

      {:reply, :ok, state} =
        Phonic.handle_call({:resolve_delegation, "alias", outcome}, nil, state)

      {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)

      assert_receive {:phonic_command,
                      %{
                        "type" => "tool_call_output",
                        "tool_call_id" => "alias",
                        "output" => %{"result" => "Verified result"}
                      }}

      assert state.response_watch != nil
      refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 10

      assert {:reply, :ok, _} =
               Phonic.handle_call({:resolve_delegation, "alias", outcome}, nil, state)

      refute_receive {:phonic_command, %{"type" => "tool_call_output"}}, 10
    end
  end

  test "native handoff accepts unmarked text audio only within its uninterrupted output epoch",
       context do
    state = ready_busy(context)
    state = deliver(context, state, call("busy", "order"))
    state = deliver(context, state, audio(:binary.copy(<<0, 0>>, 240), ""))
    assert state.inbound.bytes == 0
    bytes = :binary.copy(<<1, 0>>, 240)
    state = deliver(context, state, audio(bytes, "Let me check."))

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Let me check."}}}

    assert {:reply, {:ok, frames}, state} = Phonic.handle_call({:read, 960}, nil, state)
    assert Enum.map_join(frames, & &1.data) == bytes
    state = deliver(context, state, finished())
    {:reply, :ok, state} = Phonic.handle_call({:append, update("result", "busy")}, nil, state)
    assert_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "busy"}}
    state = deliver(context, state, audio(bytes, "Verified result"))

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Verified result"}}}

    {:reply, {:ok, _}, state} = Phonic.handle_call({:read, 960}, nil, state)
    state = deliver(context, state, finished())

    state =
      deliver(context, state, %{"type" => "tool_call_interrupted", "tool_call_id" => "busy"})

    state = deliver(context, state, call("new", "another order"))
    state = deliver(context, state, %{"type" => "user_started_speaking"})
    {:reply, :ok, state} = Phonic.handle_call({:resume_output, 1}, nil, state)
    state = deliver(context, state, audio(bytes, "Obsolete trailing speech"))
    assert state.inbound.bytes == 0

    refute_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Obsolete trailing speech"}}},
                   10

    state = deliver(context, state, started())
    state = deliver(context, state, audio(bytes, "Fresh boundary"))
    assert state.inbound.bytes > 0

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{delta: "Fresh boundary"}}}
  end

  defp ready_busy(context) do
    {:ok, config} =
      Protocol.start(
        [api_key: "private-test"],
        context.state.init.audio_format
      )

    ready(context, %{context.state | config: config, native_busy?: true})
  end

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
