defmodule Parlora.PrismAdapterTest do
  use ExUnit.Case, async: true

  alias Parlora.{AdapterInit, AudioFormat, AudioPipeline, ContextUpdate, Event, Limits}
  alias Parlora.Channels.LocalAudio
  alias Parlora.Provider.WebSocketConnection
  alias Parlora.Providers.Prism
  alias Parlora.Providers.Prism.Protocol
  alias Parlora.TestSupport.MemoryAudio

  defmodule Peer do
    def init(owner) do
      send(owner, {:peer, self()})
      {:ok, owner}
    end

    def handle_in({data, _metadata}, owner) do
      send(owner, {:wire, JSON.decode!(data)})
      {:ok, owner}
    end

    def handle_info({:event, event}, owner), do: {:push, {:text, JSON.encode!(event)}, owner}
  end

  defmodule Route do
    def init(owner), do: owner
    def call(conn, owner), do: WebSockAdapter.upgrade(conn, Peer, owner, [])
  end

  defmodule PipelineSource do
    def read_audio(owner, budget) do
      Agent.get_and_update(owner, fn state ->
        {:reply, reply, next} = Prism.handle_call({:read, budget}, nil, state)
        {reply, next}
      end)
    end
  end

  setup do
    listener = start_supervised!({Bandit, plug: {Route, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    {:ok, socket} = WebSocketConnection.connect({:http, "127.0.0.1", port}, "/", [])
    assert_receive {:peer, peer}

    init = %AdapterInit{
      session_id: "prism-test",
      adapter_id: "provider",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    options = [api_key: "fixture"]
    {:ok, config} = Protocol.start(options, init.audio_format)
    {:ok, state, _continue} = Prism.init({init, options, config})
    state = step(%{state | socket: socket})
    assert state.status == :starting
    state = deliver(state, peer, %{"type" => "session.created"})
    assert_receive {:wire, %{"type" => "session.update", "event_id" => id, "session" => settings}}
    refute_received {:parlora_event, %Event{type: :ready}}

    state =
      deliver(state, peer, %{
        "type" => "session.updated",
        "prism_request_event_id" => id,
        "session" =>
          Map.merge(settings, %{"model" => "prism", "prism_effective_interrupt_response" => true})
      })

    refute_received {:parlora_event, %Event{type: :ready}}
    state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
    assert_receive {:parlora_event, %Event{type: :ready}}
    on_exit(fn -> Prism.terminate(:normal, state) end)
    %{state: state, peer: peer}
  end

  test "continues once after the parent ends and every result is acknowledged", %{
    state: state,
    peer: peer
  } do
    state = start_reply(state, peer, "parent")
    state = tool(state, peer, "one")
    state = tool(state, peer, "two")
    state = tool(state, peer, "two")
    assert_receive {:parlora_event, %Event{type: :delegation_requested, payload: %{id: "one"}}}
    assert_receive {:parlora_event, %Event{type: :delegation_requested, payload: %{id: "two"}}}
    refute_received {:parlora_event, %Event{type: :delegation_requested}}

    update = %{result("one") | origin: :backend_result, task_id: "task-one", task_revision: 1}
    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
    assert_receive {:wire, %{"item" => %{"call_id" => "one"}, "event_id" => first}}
    refute_received {:wire, %{"item" => %{"call_id" => "one"}}}

    state = ack_result(state, peer, first, "one")

    assert_receive {:parlora_event, %Event{type: :context_acknowledged, command_id: "result-one"}}
    refute_received {:wire, %{"type" => "response.create"}}
    state = finish_reply(state, peer, "parent", "completed")
    refute_received {:wire, %{"type" => "response.create"}}

    {:reply, :ok, state} = Prism.handle_call({:append, result("two")}, nil, state)
    assert_receive {:wire, %{"item" => %{"call_id" => "two"}, "event_id" => second}}
    refute_received {:wire, %{"type" => "response.create"}}
    state = ack_result(state, peer, second, "two")

    assert_receive {:wire,
                    %{
                      "type" => "response.create",
                      "event_id" => continuation,
                      "response" => %{
                        "metadata" => %{
                          "prism_cause" => "tool_continuation",
                          "prism_parent_response_id" => "parent"
                        }
                      }
                    }}

    state = ack_result(state, peer, second, "two")
    state = accept_reply(state, peer, continuation, "continued")
    state = finish_reply(state, peer, "continued", "completed")
    _state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
    refute_received {:parlora_check_delivery, _, _, _}
    refute_received {:wire, %{"type" => "response.create"}}
  end

  test "acknowledges a late result without reviving a superseded tool round", %{
    state: state,
    peer: peer
  } do
    state = start_reply(state, peer, "parent")
    state = tool(state, peer, "old-call")
    state = finish_reply(state, peer, "parent", "completed")
    state = deliver(state, peer, %{"type" => "input_audio_buffer.speech_started"})

    {:reply, :ok, state} = Prism.handle_call({:append, result("old-call")}, nil, state)
    assert_receive {:wire, %{"item" => %{"call_id" => "old-call"}, "event_id" => id}}
    _state = ack_result(state, peer, id, "old-call")

    assert_receive {:parlora_event,
                    %Event{type: :context_acknowledged, command_id: "result-old-call"}}

    refute_received {:wire, %{"type" => "response.create"}}
  end

  for scenario <- [:silent, :already_spoke, :interrupted, :result_pending] do
    @scenario scenario
    test "recovers a verified result from a repeated call only after a silent continuation (#{scenario})",
         %{state: state, peer: peer} do
      state = start_reply(state, peer, "parent")
      state = tool(state, peer, "original")
      {:reply, :ok, state} = Prism.handle_call({:append, result("original")}, nil, state)
      assert_receive {:wire, %{"item" => %{"call_id" => "original"}, "event_id" => original}}
      state = ack_result(state, peer, original, "original")
      state = finish_reply(state, peer, "parent", "completed")
      assert_receive {:wire, %{"type" => "response.create", "event_id" => continuation}}

      state = accept_reply(state, peer, continuation, "continuation")
      state = tool(state, peer, "repeated")

      outcome = %{
        status: :associated,
        task_status: :completed,
        result_delivery:
          if(@scenario == :result_pending, do: :awaiting_provider, else: :accepted),
        result: "Shall I book Thursday at 10:15 AM?"
      }

      command = {:resolve_delegation, "repeated", outcome}
      {:reply, :ok, state} = Prism.handle_call(command, nil, state)

      assert_receive {:wire,
                      %{
                        "item" => %{"call_id" => "repeated", "output" => output},
                        "event_id" => id
                      }}

      assert JSON.decode!(output)["result"] == outcome.result

      state =
        case @scenario do
          :already_spoke -> audio(state, peer, "continuation", "spoken")
          :interrupted -> deliver(state, peer, %{"type" => "input_audio_buffer.speech_started"})
          _ -> state
        end

      state = finish_reply(state, peer, "continuation", "completed")
      refute_received {:wire, %{"type" => "response.create"}}
      state = ack_result(state, peer, id, "repeated")

      if @scenario == :silent do
        assert JSON.decode!(output)["instruction"] =~ "Speak the verified result"

        assert_receive {:wire,
                        %{
                          "type" => "response.create",
                          "event_id" => retry,
                          "response" => %{
                            "metadata" => %{"prism_parent_response_id" => "continuation"}
                          }
                        }}

        state = accept_reply(state, peer, retry, "retry")
        state = tool(state, peer, "repeat-again")

        {:reply, :ok, state} =
          Prism.handle_call({:resolve_delegation, "repeat-again", outcome}, nil, state)

        assert_receive {:wire, %{"item" => %{"call_id" => "repeat-again"}, "event_id" => again}}
        state = ack_result(state, peer, again, "repeat-again")
        _state = finish_reply(state, peer, "retry", "completed")
      end

      refute_receive {:wire, %{"type" => "response.create"}}, 50
    end
  end

  test "reports zero playback only for the matching discarded response", %{
    state: state,
    peer: peer
  } do
    state = start_reply(state, peer, "held-response")

    state =
      deliver(state, peer, %{
        "type" => "response.done",
        "response" => %{
          "id" => "held-response",
          "status" => "completed",
          "metadata" => %{"prism_drain_token" => "drain-held"}
        }
      })

    assert {:reply, {:error, %{code: :not_ready}}, state} =
             Prism.handle_call({:control, "stale", {:output_discarded, "previous"}}, nil, state)

    command = {:control, "discard", {:output_discarded, "held-response"}}
    assert {:reply, :ok, state} = Prism.handle_call(command, nil, state)

    assert_receive {:wire,
                    %{
                      "type" => "prism.playback.drained",
                      "drain_token" => "drain-held",
                      "played_ms" => 0
                    }}

    refute state.typed_ready?
    assert {:reply, :ok, _state} = Prism.handle_call(command, nil, state)
    refute_received {:wire, %{"type" => "prism.playback.drained"}}
  end

  for interruption <- [:before_submission, :before_acknowledgment], current? <- [true, false] do
    @interruption interruption
    @current current?
    test "reports a booking result after interruption #{interruption} only if current (#{current?})",
         %{
           state: state,
           peer: peer
         } do
      state = start_reply(state, peer, "parent")
      state = tool(state, peer, "booking")
      state = finish_reply(state, peer, "parent", "completed")

      state =
        if @interruption == :before_submission,
          do: interrupt_for_progress(state, peer),
          else: state

      update = %{
        result("booking")
        | origin: :backend_result,
          content: "Booked Thursday at 10:15 AM with Dr. Lee.",
          task_id: "task",
          task_revision: 2
      }

      {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)

      assert_receive {:wire,
                      %{
                        "item" => %{"call_id" => "booking", "output" => output},
                        "event_id" => id
                      }}

      assert JSON.decode!(output)["result"] == update.content

      state =
        if @interruption == :before_acknowledgment,
          do: interrupt_for_progress(state, peer),
          else: state

      state = ack_result(state, peer, id, "booking")

      assert_receive {:parlora_event,
                      %Event{type: :context_acknowledged, command_id: "result-booking"}}

      refute_received {:parlora_check_delivery, _, _, _}
      state = finish_reply(state, peer, "progress", "completed")
      state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      assert_receive {:parlora_check_delivery, _, ref, ^update}
      refute_received {:wire, %{"type" => "response.create"}}

      {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, @current}, state)

      state =
        if @current do
          assert_receive {:wire,
                          %{
                            "type" => "response.create",
                            "event_id" => reply,
                            "response" => %{
                              "metadata" => %{"prism_cause" => "proactive"},
                              "prism_call_id" => "booking"
                            }
                          }}

          state = accept_reply(state, peer, reply, "confirmation")
          state = audio(state, peer, "confirmation", "confirmation-audio")

          assert {:reply, {:ok, [%{stream_id: "confirmation-audio"}]}, state} =
                   Prism.handle_call({:read, 960}, nil, state)

          finish_reply(state, peer, "confirmation", "completed")
        else
          state
        end

      state = ack_result(state, peer, id, "booking")
      _state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      refute_received {:parlora_check_delivery, _, _, _}
      refute_receive {:wire, %{"type" => "response.create"}}, 50
    end
  end

  for {kind, error} <- [
        continue: "response_superseded",
        continue: "tool_continuation_unavailable",
        late_reply: "nudge_superseded",
        late_reply: "instructions_busy"
      ],
      current? <- [true, false] do
    @kind kind
    @error error
    @current current?
    test "recovers a booking when #{kind} receives #{error} before it starts (current: #{current?})",
         %{state: state, peer: peer} do
      update = %{
        result("booking")
        | origin: :backend_result,
          task_id: "task",
          task_revision: 2,
          content: "Booked Thursday at 10:15 AM with Dr. Lee."
      }

      state = start_reply(state, peer, "parent")
      state = tool(state, peer, "booking")
      state = finish_reply(state, peer, "parent", "completed")
      state = if @kind == :late_reply, do: interrupt_for_progress(state, peer), else: state

      {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
      assert_receive {:wire, %{"item" => %{"call_id" => "booking"}, "event_id" => result_id}}
      state = ack_result(state, peer, result_id, "booking")

      assert_receive {:parlora_event,
                      %Event{type: :context_acknowledged, command_id: "result-booking"}}

      state =
        if @kind == :late_reply do
          state = finish_reply(state, peer, "progress", "completed")
          state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
          assert_receive {:parlora_check_delivery, _, ref, ^update}
          {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, true}, state)
          state
        else
          state
        end

      assert_receive {:wire,
                      %{"type" => "response.create", "event_id" => reply, "response" => response}}

      if @kind == :continue do
        assert response["metadata"]["prism_cause"] == "tool_continuation"
      else
        assert response["prism_call_id"] == "booking"
      end

      # Exercise both possible event orders at the reply's admission boundary.
      events = [
        %{"type" => "input_audio_buffer.speech_started", "item_id" => "caller"},
        reply_rejection(reply, @error)
      ]

      events = if @current, do: events, else: Enum.reverse(events)
      state = Enum.reduce(events, state, fn event, current -> deliver(current, peer, event) end)
      state = final_transcript(state, peer, "caller", "What should I bring?")
      state = start_reply(state, peer, "interruption", ["caller"])
      refute_received {:parlora_check_delivery, _, _, _}
      state = finish_reply(state, peer, "interruption", "completed")
      state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})

      assert_receive {:parlora_check_delivery, _, ref, ^update}, 250
      refute_received {:wire, %{"type" => "response.create"}}

      {state, ref} =
        if @current do
          state = interrupt_for_progress(state, peer)

          assert {:noreply, ^state} =
                   Prism.handle_info({:parlora_delivery_current, ref, true}, state)

          state = finish_reply(state, peer, "progress", "completed")
          state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
          assert_receive {:parlora_check_delivery, _, fresh_ref, ^update}
          assert fresh_ref != ref
          {state, fresh_ref}
        else
          {state, ref}
        end

      {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, @current}, state)

      state =
        if @current do
          assert_receive {:wire,
                          %{
                            "type" => "response.create",
                            "event_id" => recovered,
                            "response" => %{
                              "metadata" => %{"prism_cause" => "proactive"},
                              "prism_call_id" => "booking"
                            }
                          }}

          state = accept_reply(state, peer, recovered, "confirmation")
          state = audio(state, peer, "confirmation", "confirmation-audio")

          assert {:reply, {:ok, [%{stream_id: "confirmation-audio"}]}, state} =
                   Prism.handle_call({:read, 960}, nil, state)

          finish_reply(state, peer, "confirmation", "completed")
        else
          state
        end

      state = deliver(state, peer, reply_rejection(reply, @error))
      _state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      refute_received {:parlora_check_delivery, _, _, _}
      refute_receive {:wire, %{"type" => "response.create"}}, 50
    end
  end

  for {path, ordering, playout} <- [
        {:continue, :speech_first, :silent},
        {:late_reply, :speech_first, :silent},
        {:late_reply, :cancel_first, :silent},
        {:late_reply, :cancel_first, :queued},
        {:continue, :speech_first, :read_older_audio},
        {:continue, :speech_first, :handed_off},
        {:continue, :speech_first, :held_in_pipeline},
        {:continue, :speech_first, :microphone_queued},
        {:continue, :speech_first, :microphone_playing}
      ] do
    @path path
    @ordering ordering
    @playout playout
    test "handles interruption after #{path} is accepted (#{ordering}, playout: #{playout})",
         %{state: state, peer: peer} do
      update = %{
        result("booking")
        | origin: :backend_result,
          task_id: "task",
          task_revision: 2,
          content: "Booked Thursday at 10:15 AM with Dr. Lee."
      }

      state = start_reply(state, peer, "parent")
      state = tool(state, peer, "booking")

      state =
        if @playout == :read_older_audio do
          state |> audio(peer, "parent", "filler") |> audio(peer, "parent", "filler")
        else
          state
        end

      state = finish_reply(state, peer, "parent", "completed")
      state = if @path == :late_reply, do: interrupt_for_progress(state, peer), else: state

      {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
      assert_receive {:wire, %{"item" => %{"call_id" => "booking"}, "event_id" => result_id}}
      state = ack_result(state, peer, result_id, "booking")

      state =
        if @path == :late_reply do
          state = finish_reply(state, peer, "progress", "completed")
          state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
          assert_receive {:parlora_check_delivery, _, ref, ^update}
          {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, true}, state)
          state
        else
          state
        end

      assert_receive {:wire, %{"type" => "response.create", "event_id" => reply}}
      state = accept_reply(state, peer, reply, "confirmation")

      state =
        if @playout == :silent,
          do: state,
          else: audio(state, peer, "confirmation", "confirmation-audio")

      state =
        case @playout do
          :read_older_audio ->
            assert {:reply, {:ok, [%{stream_id: "filler"}, %{stream_id: "filler"}]}, state} =
                     Prism.handle_call({:read, 960}, nil, state)

            state

          :handed_off ->
            assert {:reply, {:ok, [%{stream_id: "confirmation-audio"}]}, state} =
                     Prism.handle_call({:read, 960}, nil, state)

            state

          _ ->
            state
        end

      {state, pipeline} =
        if @playout in [:held_in_pipeline, :microphone_queued, :microphone_playing],
          do: start_pipeline_playout(state, @playout),
          else: {state, nil}

      speech = %{"type" => "input_audio_buffer.speech_started", "item_id" => "caller"}

      cancelled = %{
        "type" => "response.done",
        "response" => %{
          "id" => "confirmation",
          "status" => "cancelled",
          "status_details" => %{"reason" => "turn_detected"}
        }
      }

      state =
        if @ordering == :speech_first do
          state |> deliver(peer, speech) |> deliver(peer, cancelled)
        else
          state |> deliver(peer, cancelled) |> deliver(peer, speech)
        end

      assert_receive {:parlora_event,
                      %Event{
                        type: :output_interrupted,
                        payload: %{token: token, response_id: "confirmation"}
                      }}

      refute_received {:parlora_event, %Event{type: :output_interrupted}}
      position = clear_pipeline_playout(pipeline, token, @playout)
      {:reply, :ok, state} = Prism.handle_call({:resume_output, token, position}, nil, state)
      assert {:reply, {:ok, []}, state} = Prism.handle_call({:read, 960}, nil, state)

      state =
        deliver(state, peer, %{"type" => "input_audio_buffer.committed", "item_id" => "caller"})

      state = start_reply(state, peer, "follow-up", ["caller"])
      state = finish_reply(state, peer, "follow-up", "completed")
      state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      refute_received {:parlora_check_delivery, _, _, _}

      state = final_transcript(state, peer, "caller", "What should I bring?")

      if @playout not in [:handed_off, :microphone_playing] do
        assert_receive {:parlora_check_delivery, _, ref, ^update}
        {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, true}, state)

        assert_receive {:wire,
                        %{
                          "type" => "response.create",
                          "event_id" => recovered,
                          "response" => %{"prism_call_id" => "booking"}
                        }}

        state = accept_reply(state, peer, recovered, "recovered")
        state = audio(state, peer, "recovered", "recovered-audio")

        assert {:reply, {:ok, [%{stream_id: "recovered-audio"}]}, state} =
                 Prism.handle_call({:read, 960}, nil, state)

        state = finish_reply(state, peer, "recovered", "completed")
        _state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      end

      refute_received {:parlora_check_delivery, _, _, _}

      refute_receive {:wire, %{"type" => "response.create"}}, 50
      refute_received {:wire, %{"type" => "conversation.item.create"}}
    end
  end

  for outcome <- [:speaks, :times_out_again] do
    @timeout_outcome outcome
    test "retries a verified result once after a generation timeout (#{outcome})", %{
      state: state,
      peer: peer
    } do
      update = %{
        result("booking")
        | origin: :backend_result,
          task_id: "task",
          task_revision: 2,
          content: "Booked Thursday at 10:15 AM with Dr. Lee."
      }

      state = start_reply(state, peer, "parent")
      state = tool(state, peer, "booking")
      state = finish_reply(state, peer, "parent", "completed")
      {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
      assert_receive {:wire, %{"item" => %{"call_id" => "booking"}, "event_id" => result_id}}
      state = ack_result(state, peer, result_id, "booking")
      assert_receive {:wire, %{"type" => "response.create", "event_id" => reply}}
      state = accept_reply(state, peer, reply, "confirmation")
      state = time_out_reply(state, peer, "confirmation")
      refute_received {:parlora_check_delivery, _, _, _}
      state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      assert_receive {:parlora_check_delivery, _, ref, ^update}
      {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, true}, state)

      assert_receive {:wire,
                      %{
                        "type" => "response.create",
                        "event_id" => recovered,
                        "response" => %{"prism_call_id" => "booking"}
                      }}

      state = accept_reply(state, peer, recovered, "retry")

      state =
        if @timeout_outcome == :speaks do
          state = audio(state, peer, "retry", "booking-audio")

          assert {:reply, {:ok, [%{stream_id: "booking-audio"}]}, state} =
                   Prism.handle_call({:read, 960}, nil, state)

          finish_reply(state, peer, "retry", "completed")
        else
          time_out_reply(state, peer, "retry")
        end

      _state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      refute_received {:parlora_check_delivery, _, _, _}
      refute_receive {:wire, %{"type" => "response.create"}}, 50
      refute_received {:wire, %{"type" => "conversation.item.create"}}
    end
  end

  test "recovers the original booking when an interruption supersedes the repeated-tool retry", %{
    state: state,
    peer: peer
  } do
    update = %{
      result("booking")
      | origin: :backend_result,
        task_id: "task",
        task_revision: 2,
        content: "Booked Thursday at 10:15 AM with Dr. Lee."
    }

    state = start_reply(state, peer, "parent")
    state = tool(state, peer, "booking")
    state = finish_reply(state, peer, "parent", "completed")
    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
    assert_receive {:wire, %{"item" => %{"call_id" => "booking"}, "event_id" => result_id}}
    state = ack_result(state, peer, result_id, "booking")
    assert_receive {:wire, %{"type" => "response.create", "event_id" => continuation}}
    state = accept_reply(state, peer, continuation, "confirmation")
    state = tool(state, peer, "repeated")

    outcome = %{
      status: :associated,
      task_status: :completed,
      result_delivery: :accepted,
      result: update.content
    }

    {:reply, :ok, state} =
      Prism.handle_call({:resolve_delegation, "repeated", outcome}, nil, state)

    assert_receive {:wire, %{"item" => %{"call_id" => "repeated"}, "event_id" => repeated_id}}
    state = ack_result(state, peer, repeated_id, "repeated")
    state = finish_reply(state, peer, "confirmation", "completed")

    assert_receive {:wire,
                    %{
                      "type" => "response.create",
                      "event_id" => retry,
                      "response" => %{
                        "metadata" => %{"prism_parent_response_id" => "confirmation"}
                      }
                    }}

    state =
      deliver(state, peer, %{"type" => "input_audio_buffer.speech_started", "item_id" => "caller"})

    state = deliver(state, peer, reply_rejection(retry, "response_superseded"))

    state =
      deliver(state, peer, %{"type" => "input_audio_buffer.committed", "item_id" => "caller"})

    state = final_transcript(state, peer, "caller", "What should I bring?")
    state = start_reply(state, peer, "follow-up", ["caller"])
    state = finish_reply(state, peer, "follow-up", "completed")
    state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})

    assert_receive {:parlora_check_delivery, _, ref, ^update}
    {:noreply, state} = Prism.handle_info({:parlora_delivery_current, ref, true}, state)

    assert_receive {:wire,
                    %{
                      "type" => "response.create",
                      "event_id" => recovered,
                      "response" => %{"prism_call_id" => "booking"}
                    }}

    state = accept_reply(state, peer, recovered, "recovered")
    state = audio(state, peer, "recovered", "recovered-audio")

    assert {:reply, {:ok, [%{stream_id: "recovered-audio"}]}, _state} =
             Prism.handle_call({:read, 960}, nil, state)

    refute_received {:wire, %{"type" => "conversation.item.create"}}
  end

  for stage <- [:awaiting_ack, :waiting_for_idle, :checking_revision] do
    @stage stage
    test "retains a pending booking across another interruption while #{stage}", %{
      state: state,
      peer: peer
    } do
      state = start_reply(state, peer, "parent")
      state = tool(state, peer, "booking")
      state = finish_reply(state, peer, "parent", "completed")
      state = interrupt_for_progress(state, peer)

      update = %{result("booking") | origin: :backend_result, task_id: "task", task_revision: 2}
      {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
      assert_receive {:wire, %{"item" => %{"call_id" => "booking"}, "event_id" => id}}
      state = if @stage == :awaiting_ack, do: state, else: ack_result(state, peer, id, "booking")
      state = finish_reply(state, peer, "progress", "completed")

      {state, old_ref} =
        if @stage == :checking_revision do
          state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
          assert_receive {:parlora_check_delivery, _, ref, ^update}
          {state, ref}
        else
          {state, nil}
        end

      state = interrupt_for_progress(state, peer)
      state = if @stage == :awaiting_ack, do: ack_result(state, peer, id, "booking"), else: state

      assert_receive {:parlora_event,
                      %Event{type: :context_acknowledged, command_id: "result-booking"}}

      assert {:noreply, ^state} =
               Prism.handle_info({:parlora_delivery_current, old_ref, true}, state)

      refute_received {:wire, %{"type" => "response.create"}}

      state = finish_reply(state, peer, "progress", "completed")
      state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
      assert_receive {:parlora_check_delivery, _, fresh_ref, ^update}, 250
      assert fresh_ref != old_ref
      {:noreply, _state} = Prism.handle_info({:parlora_delivery_current, fresh_ref, true}, state)

      assert_receive {:wire,
                      %{
                        "type" => "response.create",
                        "response" => %{"prism_call_id" => "booking"}
                      }}
    end
  end

  test "reports a superseded emergency nudge as retryable", %{state: state, peer: peer} do
    update = %{
      result("emergency")
      | delegation_id: nil,
        content: "Please hang up and call 911 now."
    }

    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)

    assert_receive {:wire,
                    %{
                      "type" => "response.create",
                      "event_id" => id,
                      "response" => %{"prism_instruction" => "Please hang up and call 911 now."}
                    }}

    _state = deliver(state, peer, reply_rejection(id, "nudge_superseded"))

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_rejected,
                      command_id: "result-emergency",
                      payload: %{
                        error: %{
                          code: :backpressure,
                          details: %{provider_code: "nudge_superseded"}
                        }
                      }
                    }},
                   250
  end

  test "correlates an accepted nudge with its response timeout", %{state: state, peer: peer} do
    update = %{
      result("emergency")
      | delegation_id: nil,
        content: "Please hang up and call 911 now."
    }

    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
    assert_receive {:wire, %{"type" => "response.create", "event_id" => id}}
    state = accept_reply(state, peer, id, "guidance")

    assert_receive {:parlora_event,
                    %Event{
                      type: :context_acknowledged,
                      command_id: "result-emergency",
                      payload: %{acceptance: :response_created, response_id: "guidance"}
                    }}

    _state =
      deliver(state, peer, %{
        "type" => "response.done",
        "response" => %{
          "id" => "guidance",
          "status" => "failed",
          "status_details" => %{"reason" => "response_timeout"}
        }
      })

    assert_receive {:parlora_event,
                    %Event{
                      type: :provider_activity,
                      payload: %{
                        state: :idle,
                        response_id: "guidance",
                        status: "failed",
                        reason: "response_timeout"
                      }
                    }}
  end

  test "keeps an acknowledged booking when the caller interrupts a round with another pending tool",
       %{
         state: state,
         peer: peer
       } do
    state = start_reply(state, peer, "parent")
    state = tool(state, peer, "booking")
    state = tool(state, peer, "other")
    state = finish_reply(state, peer, "parent", "completed")

    update = %{result("booking") | origin: :backend_result, task_id: "task", task_revision: 2}
    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
    assert_receive {:wire, %{"item" => %{"call_id" => "booking"}, "event_id" => result_id}}
    state = ack_result(state, peer, result_id, "booking")
    refute_received {:wire, %{"type" => "response.create"}}

    state = interrupt_for_progress(state, peer)
    state = finish_reply(state, peer, "progress", "completed")
    _state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})

    assert_receive {:parlora_check_delivery, _, _, ^update}
    refute_received {:wire, %{"type" => "response.create"}}
  end

  test "waits for committed caller transcripts before checking a late result", %{
    state: state,
    peer: peer
  } do
    state = start_reply(state, peer, "parent")
    state = tool(state, peer, "search")
    state = finish_reply(state, peer, "parent", "completed")
    update = %{result("search") | origin: :backend_result, task_id: "task", task_revision: 1}
    {:reply, :ok, state} = Prism.handle_call({:append, update}, nil, state)
    assert_receive {:wire, %{"item" => %{"call_id" => "search"}, "event_id" => id}}

    state = deliver(state, peer, %{"type" => "input_audio_buffer.speech_started"})

    state =
      Enum.reduce(["first", "correction"], state, fn item, current ->
        deliver(current, peer, %{"type" => "input_audio_buffer.committed", "item_id" => item})
      end)

    state = start_reply(state, peer, "caller-reply", ["first", "correction"])
    state = ack_result(state, peer, id, "search")
    state = finish_reply(state, peer, "caller-reply", "completed")
    state = deliver(state, peer, %{"type" => "prism.typed_input.ready"})
    refute_received {:parlora_check_delivery, _, _, _}

    state =
      deliver(state, peer, %{
        "type" => "conversation.item.input_audio_transcription.failed",
        "item_id" => "first"
      })

    refute_received {:parlora_check_delivery, _, _, _}
    _state = final_transcript(state, peer, "correction", "November fifth instead.")

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{segment_id: "correction"}}}

    assert_receive {:parlora_check_delivery, _, _, ^update}
  end

  test "publishes a tool call only after the final transcripts of the turns it answers", %{
    state: state,
    peer: peer
  } do
    state = final_transcript(state, peer, "first", "Yes, that is correct.")

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{segment_id: "first"}}}

    state = start_reply(state, peer, "parent", ["first", "correction"])
    state = tool(state, peer, "lookup")
    state = finish_reply(state, peer, "parent", "completed")
    refute_received {:parlora_event, %Event{type: :delegation_requested}}

    state = final_transcript(state, peer, "other", "An unrelated transcript")

    assert_receive {:parlora_event,
                    %Event{type: :transcript_delta, payload: %{segment_id: "other"}}}

    refute_received {:parlora_event, %Event{type: :delegation_requested}}

    _state = final_transcript(state, peer, "correction", "I prefer November fifth.")

    assert %Event{type: :transcript_delta, payload: %{segment_id: "correction"}} =
             transcript_or_delegation()

    assert %Event{type: :delegation_requested, payload: %{id: "lookup"}} =
             transcript_or_delegation()
  end

  test "a failed caller transcript asks for a repeat without delegating against old context", %{
    state: state,
    peer: peer
  } do
    state = start_reply(state, peer, "parent", ["unrecognized"])
    state = tool(state, peer, "lookup")

    state =
      deliver(state, peer, %{
        "type" => "conversation.item.input_audio_transcription.failed",
        "item_id" => "unrecognized"
      })

    refute_received {:parlora_event, %Event{type: :delegation_requested}}

    assert_receive {:wire,
                    %{"item" => %{"call_id" => "lookup", "output" => output}, "event_id" => id}}

    assert JSON.decode!(output)["status"] == "missing_transcript"

    state = ack_result(state, peer, id, "lookup")
    refute_received {:wire, %{"type" => "response.create"}}
    _state = finish_reply(state, peer, "parent", "completed")
    assert_receive {:wire, %{"type" => "response.create"}}
  end

  test "new speech supersedes an unpublished call even if its transcript eventually arrives", %{
    state: state,
    peer: peer
  } do
    state = start_reply(state, peer, "parent", ["old"])
    state = tool(state, peer, "lookup")
    state = deliver(state, peer, %{"type" => "input_audio_buffer.speech_started"})
    assert_receive {:wire, %{"item" => %{"call_id" => "lookup", "output" => output}}}
    assert JSON.decode!(output) == %{"status" => "superseded"}

    _state = final_transcript(state, peer, "old", "My first request.")
    refute_received {:parlora_event, %Event{type: :delegation_requested}}
  end

  for phase <- [:generating, :queued] do
    @phase phase
    test "clears #{@phase} output and holds fresh audio through the barrier", %{
      state: state,
      peer: peer
    } do
      state = start_reply(state, peer, "old")
      state = audio(state, peer, "old", "old-item")

      state =
        if @phase == :queued, do: finish_reply(state, peer, "old", "completed"), else: state

      state = deliver(state, peer, %{"type" => "input_audio_buffer.speech_started"})
      assert_receive {:parlora_event, %Event{type: :output_interrupted, payload: %{token: 1}}}

      state =
        if @phase == :generating do
          state = audio(state, peer, "old", "old-item")
          finish_reply(state, peer, "old", "cancelled")
        else
          state
        end

      state = start_reply(state, peer, "new")
      state = audio(state, peer, "new", "new-item")
      assert {:reply, {:ok, []}, _} = Prism.handle_call({:read, 960}, nil, state)
      {:reply, :ok, state} = Prism.handle_call({:resume_output, 0, nil}, nil, state)
      assert {:reply, {:ok, []}, _} = Prism.handle_call({:read, 960}, nil, state)

      {:reply, :ok, state} =
        Prism.handle_call(
          {:resume_output, 1, %{stream_id: "old-item", played_ms: 10}},
          nil,
          state
        )

      assert_receive {:wire,
                      %{
                        "type" => "conversation.item.truncate",
                        "event_id" => report,
                        "item_id" => "old-item",
                        "audio_end_ms" => 10
                      }}

      state =
        deliver(state, peer, %{
          "type" => "conversation.item.truncated",
          "prism_request_event_id" => report,
          "item_id" => "old-item",
          "audio_end_ms" => 10,
          "prism_kept_text" => ""
        })

      assert_receive {:parlora_event,
                      %Event{type: :output_truncated, payload: %{stream_id: "old-item"}}}

      assert {:reply, {:ok, [%{stream_id: "new-item"}]}, _} =
               Prism.handle_call({:read, 960}, nil, state)
    end
  end

  defp start_pipeline_playout(state, mode) do
    {:ok, source} = Agent.start_link(fn -> state end)
    init = %{state.init | adapter_id: "playback"}

    destination =
      case mode do
        :held_in_pipeline ->
          {:ok, channel} = MemoryAudio.start_link(init, :channel, [])
          {MemoryAudio, channel}

        _microphone ->
          buffer_ms = if mode == :microphone_queued, do: 200, else: 0

          options = [
            device: :synthetic,
            playback_buffering: :fixed,
            playback_buffer_ms: buffer_ms
          ]

          channel =
            start_supervised!(%{
              id: LocalAudio,
              start: {LocalAudio, :start_link, [init, options]}
            })

          assert_receive {:parlora_event, %Event{source: :channel, type: :ready}}, 1_000
          {LocalAudio, channel}
      end

    {:ok, pipeline} =
      AudioPipeline.init(
        init: init,
        direction: :output,
        source: {PipelineSource, source},
        destination: destination
      )

    assert_receive :tick

    pipeline =
      if mode == :held_in_pipeline do
        {:reply, :ok, pipeline} =
          AudioPipeline.handle_call({:control, "hold", {:hold_output, :hold}}, nil, pipeline)

        pipeline
      else
        pipeline
      end

    {:noreply, pipeline} = AudioPipeline.handle_info(:tick, pipeline)

    case {mode, destination} do
      {:held_in_pipeline, {MemoryAudio, channel}} ->
        assert pipeline.held.bytes == 480
        assert MemoryAudio.drain(channel) == []

      {:microphone_playing, {LocalAudio, channel}} ->
        await_handoff(channel, 100)

      _queued ->
        assert_receive {:parlora_event,
                        %Event{
                          type: :playback_observed,
                          payload: %{stage: :queued, stream_id: "confirmation-audio"}
                        }}
    end

    state = Agent.get(source, & &1)
    assert state.inbound.bytes == 0
    {state, pipeline}
  end

  defp await_handoff(_channel, 0), do: flunk("The synthetic device did not start the reply")

  defp await_handoff(channel, remaining) do
    if :sys.get_state(channel).playback_progress.last_handed_off_sequence == nil do
      Process.sleep(5)
      await_handoff(channel, remaining - 1)
    end
  end

  defp clear_pipeline_playout(nil, _token, _mode), do: nil

  defp clear_pipeline_playout(pipeline, token, mode) do
    {:reply, {:ok, position}, pipeline} =
      AudioPipeline.handle_call(
        {:control, "clear", {:provider_interrupted, token, :position}},
        nil,
        pipeline
      )

    case mode do
      :held_in_pipeline ->
        assert pipeline.held.bytes == 0
        assert %{last_forwarded_sequence: nil} = position

      :microphone_queued ->
        assert %{last_handed_off_sequence: nil} = position

      :microphone_playing ->
        assert %{last_handed_off_sequence: 0} = position
    end

    position
  end

  defp time_out_reply(state, peer, id) do
    state =
      deliver(state, peer, %{
        "type" => "error",
        "error" => %{
          "code" => "response_timeout",
          "scope" => "response",
          "type" => "server_error",
          "owner" => %{"kind" => "response", "response_id" => id}
        }
      })

    deliver(state, peer, %{
      "type" => "response.done",
      "response" => %{
        "id" => id,
        "status" => "failed",
        "status_details" => %{"reason" => "response_timeout"}
      }
    })
  end

  defp start_reply(state, peer, id, inputs \\ []),
    do:
      deliver(state, peer, %{
        "type" => "response.created",
        "response" => %{"id" => id, "prism_input_item_ids" => inputs}
      })

  defp accept_reply(state, peer, request, id),
    do:
      deliver(state, peer, %{
        "type" => "response.created",
        "prism_request_event_id" => request,
        "response" => %{"id" => id}
      })

  defp interrupt_for_progress(state, peer) do
    state = deliver(state, peer, %{"type" => "input_audio_buffer.speech_started"})
    start_reply(state, peer, "progress")
  end

  defp reply_rejection(request, code) do
    %{
      "type" => "error",
      "error" => %{
        "code" => code,
        "event_id" => request,
        "scope" => "event",
        "owner" => %{"kind" => "event", "event_id" => request}
      }
    }
  end

  defp final_transcript(state, peer, item, text),
    do:
      deliver(state, peer, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "item_id" => item,
        "transcript" => text
      })

  defp transcript_or_delegation do
    assert_receive {:parlora_event, %Event{type: type} = event}
                   when type in [:transcript_delta, :delegation_requested]

    event
  end

  defp finish_reply(state, peer, id, status),
    do:
      deliver(state, peer, %{
        "type" => "response.done",
        "response" => %{"id" => id, "status" => status}
      })

  defp audio(state, peer, id, item),
    do:
      deliver(state, peer, %{
        "type" => "response.audio.delta",
        "response_id" => id,
        "item_id" => item,
        "delta" => Base.encode64(:binary.copy(<<1, 0>>, 240))
      })

  defp tool(state, peer, id),
    do:
      deliver(state, peer, %{
        "type" => "response.function_call_arguments.done",
        "response_id" => state.response,
        "call_id" => id,
        "name" => "delegate_to_backend",
        "arguments" => JSON.encode!(%{request: "Look up the order"})
      })

  defp ack_result(state, peer, wire_id, call_id),
    do:
      deliver(state, peer, %{
        "type" => "conversation.item.created",
        "prism_request_event_id" => wire_id,
        "item" => %{"type" => "function_call_output", "call_id" => call_id}
      })

  defp result(call_id),
    do: %ContextUpdate{
      id: "result-" <> call_id,
      kind: :speakable,
      content: "Order ready.",
      provider_generation: 0,
      delegation_id: call_id
    }

  defp deliver(state, peer, event) do
    send(peer, {:event, event})
    step(state)
  end

  defp step(state) do
    assert_receive {:tcp, _socket, _bytes} = message
    {:noreply, state} = Prism.handle_info(message, state)
    state
  end
end
