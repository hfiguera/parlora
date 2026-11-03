defmodule Parlora.PhonicSessionTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, ContextUpdate, Event}
  alias Parlora.TestSupport.{FakeBackend, MemoryChannel, OrderPolicy, PhonicPeer}

  defmodule AssociationPolicy do
    @behaviour Parlora.ContextPolicy

    @impl true
    def interpret(snapshot, trigger, options) do
      case OrderPolicy.interpret(snapshot, trigger, options) do
        {:ok, []} ->
          with {id, _entry} <-
                 Enum.find(snapshot.pending_delegations, &(elem(&1, 1).status == :pending)),
               {task_id, task} <- Enum.at(snapshot.tasks, 0) do
            {:ok,
             [
               %Parlora.ContextDecision{
                 kind: :associate_delegation,
                 delegation_id: id,
                 task_id: task_id,
                 expected_task_revision: task.revision
               }
             ]}
          else
            _ -> {:ok, []}
          end

        result ->
          result
      end
    end
  end

  defmodule LocalProvider do
    @moduledoc false
    use GenServer
    use Parlora.ProviderClient, protocol: Parlora.Providers.Phonic.Protocol
    alias Parlora.Provider.WebSocketConnection
    alias Parlora.Providers.Phonic

    defoverridable start_link: 2

    def start_link(init, options) do
      with {:ok, config} <-
             Parlora.Providers.Phonic.Protocol.start(
               Keyword.delete(options, :port),
               init.audio_format
             ) do
        GenServer.start_link(__MODULE__, {init, options, config})
      end
    end

    @impl true
    def init({init, options, config}) do
      {:ok, state, continue} = Phonic.init({init, options, config})
      {:ok, Map.put(state, :test_port, Keyword.fetch!(options, :port)), continue}
    end

    @impl true
    def handle_continue(:connect, state) do
      {:ok, socket} =
        WebSocketConnection.connect({:http, "127.0.0.1", state.test_port}, "/v1/sts/ws", [])

      {:noreply, %{state | socket: socket}}
    end

    @impl true
    defdelegate handle_call(message, from, state), to: Phonic
    @impl true
    defdelegate handle_info(message, state), to: Phonic
    @impl true
    defdelegate terminate(reason, state), to: Phonic
    @impl true
    defdelegate resume_output(pid, token), to: Phonic
    @impl true
    defdelegate resolve_delegation(pid, id, outcome), to: Phonic
    @impl true
    defdelegate resolve_delegation(pid, id, outcome, metadata), to: Phonic
    @impl true
    defdelegate audio_limits(format), to: Phonic
  end

  setup do
    listener =
      start_supervised!({Bandit, plug: {PhonicPeer.Route, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{port: port}
  end

  for {codec, format} <- [pcm: %AudioFormat{}, pcmu: AudioFormat.pcmu()],
      native_busy? <- [false, true, :default] do
    @format format
    @native_busy native_busy?
    test "#{codec} session with native busy=#{native_busy?} corrects work and rejects stale results",
         context do
      {session, server, _channel, backend} =
        boot(context.port, @format, OrderPolicy, @native_busy)

      emit(server, %{"type" => "input_text", "text" => "order 123"})

      emit(server, %{
        "type" => "tool_call",
        "tool_call_id" => "request",
        "tool_name" => "delegate_to_backend",
        "parameters" => %{"request" => "order 123"}
      })

      assert_receive {:submitted, original}
      emit(server, %{"type" => "input_text", "text" => "Actually order 124"})
      assert_receive {:submitted, replacement}
      assert replacement.task_id == original.task_id
      assert replacement.task_revision == original.task_revision + 1
      :ok = FakeBackend.complete(backend, original, "Obsolete order 123")
      :ok = FakeBackend.complete(backend, replacement, "Current verified order 124")
      assert_receive {:parlora_event, %Event{type: :stale_result, request_id: stale}}
      assert stale == original.id

      assert_receive {:phonic_command,
                      %{
                        "type" => "tool_call_output",
                        "tool_call_id" => "request",
                        "output" => %{"result" => "Current verified order 124"}
                      }}

      refute_receive {:phonic_command, %{"output" => %{"result" => "Obsolete order 123"}}}, 20

      if @native_busy,
        do: refute_receive({:phonic_command, %{"type" => "generate_reply"}}, 20),
        else: assert_receive({:phonic_command, %{"type" => "generate_reply"}})

      emit(server, %{
        "type" => "tool_call_output_processed",
        "tool_call_id" => "request",
        "timed_out" => false
      })

      assert_receive {:parlora_event,
                      %Event{
                        type: :result_delivery,
                        request_id: current,
                        payload: %{stage: :accepted}
                      }}

      assert current == replacement.id
      assert Parlora.status(session).jobs[current].delivery == :accepted
      assert :ok = Parlora.close(session)
      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    end
  end

  test "socket loss closes the whole session without replaying pending backend work", context do
    {session, server, channel, backend} = boot(context.port, %AudioFormat{})
    emit(server, %{"type" => "input_text", "text" => "order 123"})

    emit(server, %{
      "type" => "tool_call",
      "tool_call_id" => "request",
      "tool_name" => "delegate_to_backend",
      "parameters" => %{"request" => "order 123"}
    })

    assert_receive {:submitted, _request}
    monitors = Enum.map([session, channel, backend], &Process.monitor/1)
    send(server, :disconnect)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason})
    refute_receive {:submitted, _}, 20
  end

  test "a real session resumes a completed late association without another backend request",
       context do
    {session, server, _channel, backend} = boot(context.port, %AudioFormat{}, AssociationPolicy)
    emit(server, %{"type" => "input_text", "text" => "order 124"})
    emit(server, call("original"))
    assert_receive {:submitted, request}
    :ok = FakeBackend.complete(backend, request, "Current verified order 124")

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    emit(server, %{"type" => "tool_call_output_processed", "tool_call_id" => "original"})
    assert_receive {:parlora_event, %Event{type: :result_delivery, payload: %{stage: :accepted}}}
    # The result reply yielded to a late tool call before producing speech.
    emit(server, call("late"))

    assert_receive {:phonic_command,
                    %{
                      "type" => "tool_call_output",
                      "tool_call_id" => "late",
                      "output" => %{
                        "status" => "associated",
                        "task_status" => "completed",
                        "result_delivery" => "accepted",
                        "result" => "Current verified order 124"
                      }
                    }}

    assert_receive {:phonic_command, %{"type" => "generate_reply"}}
    refute_receive {:submitted, _duplicate}, 20
    assert map_size(Parlora.status(session).jobs) == 1
  end

  test "default native replies retain completed facts across a late association without re-execution",
       context do
    {session, server, channel, backend} =
      boot(context.port, %AudioFormat{}, AssociationPolicy, :default)

    emit(server, %{"type" => "input_text", "text" => "order 124"})
    emit(server, call("original"))
    assert_receive {:submitted, request}
    :ok = FakeBackend.complete(backend, request, "Current verified order 124")

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    emit(server, %{"type" => "tool_call_output_processed", "tool_call_id" => "original"})
    assert_receive {:parlora_event, %Event{type: :result_delivery, payload: %{stage: :accepted}}}
    emit(server, %{"type" => "assistant_started_speaking"})

    emit(server, %{
      "type" => "audio_chunk",
      "audio" => Base.encode64(:binary.copy(<<1, 0>>, 240)),
      "text" => "Let me check that."
    })

    emit(server, %{"type" => "assistant_finished_speaking"})
    emit(server, call("alias"))

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "alias", "output" => output}}

    assert output["result"] == "Current verified order 124"
    assert output["instruction"] =~ "Do not repeat"

    emit(server, %{
      "type" => "audio_chunk",
      "audio" => Base.encode64(:binary.copy(<<2, 0>>, 240)),
      "text" => "Let me check again."
    })

    emit(server, %{"type" => "assistant_started_speaking"})
    emit(server, %{"type" => "assistant_finished_speaking"})
    verified = :binary.copy(<<3, 0>>, 240)

    emit(server, %{
      "type" => "audio_chunk",
      "audio" => Base.encode64(verified),
      "text" => output["result"]
    })

    emit(server, %{"type" => "assistant_finished_speaking"})

    assert_receive {:parlora_event,
                    %Event{
                      type: :transcript_delta,
                      payload: %{speaker: :assistant, delta: "Current verified order 124"}
                    }}

    assert_receive {:audio_written, ^channel, %Parlora.AudioFrame{data: ^verified}}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 20
    refute_receive {:submitted, _duplicate}, 20
    assert map_size(Parlora.status(session).jobs) == 1
  end

  @tag :handoff_boundaries
  test "an acknowledgment ending after a native association cannot drop its verified session audio",
       context do
    {session, server, channel, backend} =
      boot(context.port, %AudioFormat{}, AssociationPolicy, :default)

    emit(server, %{"type" => "input_text", "text" => "order 124"})
    emit(server, call("original"))
    assert_receive {:submitted, request}
    :ok = FakeBackend.complete(backend, request, "Current verified order 124")

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    emit(server, %{"type" => "tool_call_output_processed", "tool_call_id" => "original"})
    assert_receive {:parlora_event, %Event{type: :result_delivery, payload: %{stage: :accepted}}}
    emit(server, %{"type" => "assistant_started_speaking"})
    ack = :binary.copy(<<1, 0>>, 240)
    emit(server, %{"type" => "audio_chunk", "audio" => Base.encode64(ack), "text" => "Okay."})
    assert_receive {:audio_written, ^channel, %Parlora.AudioFrame{data: ^ack}}
    emit(server, call("alias"))

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "alias", "output" => output}}

    assert output["result"] == "Current verified order 124"
    emit(server, %{"type" => "assistant_started_speaking"})
    emit(server, %{"type" => "assistant_finished_speaking"})
    verified = :binary.copy(<<2, 0>>, 240)

    emit(server, %{
      "type" => "audio_chunk",
      "audio" => Base.encode64(verified),
      "text" => output["result"]
    })

    emit(server, %{"type" => "assistant_finished_speaking"})

    assert_receive {:parlora_event,
                    %Event{
                      type: :transcript_delta,
                      payload: %{speaker: :assistant, delta: "Current verified order 124"}
                    }}

    assert_receive {:audio_written, ^channel, %Parlora.AudioFrame{data: ^verified}}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 20
    refute_receive {:submitted, _duplicate}, 20
    assert map_size(Parlora.status(session).jobs) == 1
  end

  test "a native association to existing work remains busy until that task's verified result",
       context do
    {session, server, _channel, backend} =
      boot(context.port, %AudioFormat{}, AssociationPolicy, true)

    emit(server, %{"type" => "input_text", "text" => "order 124"})
    emit(server, call("original"))
    assert_receive {:submitted, request}

    clarification = %ContextUpdate{
      id: "clarification",
      kind: :speakable,
      provider_generation: 0,
      delegation_id: "original",
      task_id: request.task_id,
      task_revision: request.task_revision,
      content: "Which order color?"
    }

    assert :ok = Parlora.append_context(session, clarification)

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "original"}}

    emit(server, %{"type" => "assistant_chose_not_to_respond"})
    emit(server, call("alias"))
    assert_receive {:parlora_event, %Event{type: :delegation_associated, payload: %{id: "alias"}}}

    refute_receive {:phonic_command, %{"type" => "tool_call_output", "tool_call_id" => "alias"}},
                   20

    refute_receive {:submitted, _duplicate}, 20
    :ok = FakeBackend.complete(backend, request, "Current verified order 124")

    assert_receive {:phonic_command,
                    %{"type" => "tool_call_output", "tool_call_id" => "alias", "output" => output}}

    assert output == %{"result" => "Current verified order 124"}
    refute_receive {:phonic_command, %{"type" => "generate_reply"}}, 20
    emit(server, %{"type" => "tool_call_output_processed", "tool_call_id" => "alias"})
    request_id = request.id

    assert_receive {:parlora_event,
                    %Event{
                      type: :result_delivery,
                      request_id: ^request_id,
                      payload: %{stage: :accepted}
                    }}

    assert map_size(Parlora.status(session).jobs) == 1
  end

  defp boot(port, format, policy \\ OrderPolicy, native_busy? \\ false) do
    overrides = if native_busy? == :default, do: [], else: [wait_for_response: native_busy?]
    native_busy? = native_busy? != false

    caps = %Parlora.Channel.Capabilities{
      input_formats: [format],
      output_formats: [format],
      full_duplex?: true
    }

    {:ok, session} =
      Parlora.start_session(
        audio_format: format,
        provider: {LocalProvider, [api_key: "private-test", port: port] ++ overrides},
        channel: {MemoryChannel, observer: self(), capabilities: caps, observe_writes: true},
        backend: {FakeBackend, observer: self()},
        context_policy: {policy, []},
        event_sink: self()
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:phonic_peer, server}

    assert_receive {:phonic_command,
                    %{
                      "type" => "config",
                      "model" => "phonic-1",
                      "input_format" => "pcm_24000",
                      "enable_assistant_backchannel" => true,
                      "assistant_backchannel_aggressiveness" => 0.3,
                      "tools" => [
                        %{
                          "allow_tool_chaining" => false,
                          "wait_for_response" => ^native_busy?,
                          "require_speech_before_tool_call" => true,
                          "wait_for_speech_before_tool_call" => false
                        }
                      ]
                    }}

    emit(server, %{"type" => "ready_to_start_conversation"})
    emit(server, %{"type" => "conversation_created", "conversation_id" => "conv-test"})
    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :backend, backend}
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    {session, server, channel, backend}
  end

  defp emit(server, message), do: send(server, {:phonic_event, message})

  defp call(id),
    do: %{
      "type" => "tool_call",
      "tool_call_id" => id,
      "tool_name" => "delegate_to_backend",
      "parameters" => %{"request" => "order 124"}
    }
end
