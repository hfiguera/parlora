defmodule Parlora.PhonicSessionTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, Event}
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
    defdelegate audio_limits(format), to: Phonic
  end

  setup do
    listener =
      start_supervised!({Bandit, plug: {PhonicPeer.Route, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{port: port}
  end

  for {codec, format} <- [pcm: %AudioFormat{}, pcmu: AudioFormat.pcmu()] do
    @format format
    test "#{codec} session corrects work, rejects stale results and correlates provider processing",
         context do
      {session, server, _channel, backend} = boot(context.port, @format)
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
    emit(server, %{"type" => "assistant_started_speaking"})
    emit(server, %{"type" => "assistant_finished_speaking"})
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

  defp boot(port, format, policy \\ OrderPolicy) do
    caps = %Parlora.Channel.Capabilities{
      input_formats: [format],
      output_formats: [format],
      full_duplex?: true
    }

    {:ok, session} =
      Parlora.start_session(
        audio_format: format,
        provider: {LocalProvider, api_key: "private-test", port: port},
        channel: {MemoryChannel, observer: self(), capabilities: caps},
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
                      "tools" => [%{"allow_tool_chaining" => false, "wait_for_response" => false}]
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
