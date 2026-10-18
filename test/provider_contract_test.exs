defmodule Parlora.ProviderContractTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFormat, AudioFrame, ContextUpdate, Event}

  alias Parlora.TestSupport.{
    ContractProvider,
    FakeBackend,
    MemoryAudio,
    MemoryChannel,
    OrderPolicy
  }

  for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
    @format format
    test "independent provider carries duplex audio and correlated results in #{format.codec}" do
      {session, channel, provider, backend} = boot(@format, delay_context_ack: true)
      assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
      assert {:ok, capabilities} = ContractProvider.capabilities(provider)
      assert capabilities.context_update_kinds == [:speakable]
      assert capabilities.transcripts == [:user]
      refute capabilities.input_mute?
      refute capabilities.usage?
      refute function_exported?(ContractProvider, :output_buffer_status, 1)

      assert {:error, %{code: :unsupported}} = Parlora.control(session, {:input_muted, true})

      for kind <- [:quiet, :instruction] do
        assert {:error, %{code: :unsupported}} =
                 Parlora.append_context(session, %ContextUpdate{
                   id: Atom.to_string(kind),
                   kind: kind,
                   content: "Unsupported",
                   provider_generation: 0
                 })
      end

      :ok =
        MemoryAudio.inject(provider, :delegation_requested, %{
          id: "work",
          target: :client,
          offset_ms: nil
        })

      :ok =
        MemoryAudio.inject(provider, :transcript_delta, %{
          speaker: :user,
          delta: "order 124",
          start_ms: nil,
          end_ms: nil
        })

      assert_receive {:submitted, request}
      assert request.delegation_id == "work"
      assert request.input == %{order: "124"}

      captured = AudioFrame.new(AudioFormat.silence(@format, 10), @format, "caller", 0)
      generated = %{captured | stream_id: "assistant"}
      assert :ok = MemoryAudio.audio(channel, captured)
      assert :ok = MemoryAudio.audio(provider, generated)
      await_frame(provider, captured)
      await_frame(channel, %{generated | playback_epoch: 0})
      assert Parlora.status(session).jobs[request.id].status == :submitted

      assert :ok = FakeBackend.complete(backend, request, "Order 124 arrives today")
      assert_receive {:context, %ContextUpdate{kind: :speakable, delegation_id: "work", id: id}}

      assert_receive {:parlora_event,
                      %Event{type: :result_delivery, payload: %{stage: :awaiting_provider}}}

      assert Parlora.status(session).jobs[request.id].delivery == :awaiting_provider

      :ok = MemoryAudio.inject(provider, :context_acknowledged, %{}, command_id: id)

      assert_receive {:parlora_event,
                      %Event{
                        type: :result_delivery,
                        command_id: ^id,
                        payload: %{stage: :accepted}
                      }}

      assert Parlora.status(session).jobs[request.id].delivery == :accepted
      close_and_observe(session, [channel, provider, backend])
    end
  end

  for {feature, override} <- [
        full_duplex?: false,
        delegation_modes: [],
        context_update_kinds: [:quiet, :instruction],
        audio_formats: [AudioFormat.pcmu()]
      ] do
    @feature feature
    @override override
    test "missing required provider capability #{@feature} fails before readiness and cleans up" do
      caps = Map.put(ContractProvider.profile(%AudioFormat{}), @feature, @override)

      {session, channel, provider, backend} =
        boot(%AudioFormat{}, capabilities: caps, delay_ready: true)

      monitors = Enum.map([session, channel, provider, backend], &Process.monitor/1)
      send(provider, :ready)

      assert_receive {:parlora_event,
                      %Event{
                        source: :session,
                        type: :failed,
                        payload: %{error: %{code: :unsupported}}
                      }}

      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
      for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason})
      refute_received {:parlora_event, %Event{source: :session, type: :ready}}
      refute_received {:submitted, _request}
    end
  end

  test "transcripts, usage, mute and a same-format-only restriction are not startup requirements" do
    caps = %{
      ContractProvider.profile(%AudioFormat{})
      | transcripts: [],
        same_format_both_directions?: false
    }

    {session, channel, provider, backend} = boot(%AudioFormat{}, capabilities: caps)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    close_and_observe(session, [channel, provider, backend])
  end

  test "a socket submission stays unconfirmed and model idle does not finish backend work" do
    {session, channel, provider, backend} = boot(%AudioFormat{}, delay_context_ack: true)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "call",
      target: :client,
      offset_ms: nil
    })

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "order 124",
      start_ms: nil,
      end_ms: nil
    })

    assert_receive {:submitted, request}
    MemoryAudio.inject(provider, :provider_activity, %{state: :idle})
    assert Parlora.status(session).jobs[request.id].status == :submitted
    assert Parlora.status(session).provider_activity == :idle
    FakeBackend.complete(backend, request, "Order 124 arrives Friday")
    assert_receive {:context, %ContextUpdate{id: id}}
    MemoryAudio.inject(provider, :context_submitted, %{outcome: :unconfirmed}, command_id: id)

    assert_receive {:parlora_event,
                    %Event{type: :result_delivery, payload: %{stage: :unconfirmed}}}

    assert Parlora.status(session).jobs[request.id].delivery == :unconfirmed
    close_and_observe(session, [channel, provider, backend])
  end

  test "provider cancellation suppresses late results without claiming backend completion" do
    {session, channel, provider, backend} = boot(%AudioFormat{}, delay_context_ack: true)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}

    MemoryAudio.inject(provider, :delegation_requested, %{
      id: "old-call",
      target: :client,
      offset_ms: nil
    })

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: "order 123",
      start_ms: nil,
      end_ms: nil
    })

    assert_receive {:submitted, old}

    MemoryAudio.inject(provider, :delegation_cancelled, %{
      id: "old-call",
      reason: :provider_cancelled
    })

    assert_receive {:parlora_event, %Event{type: :cancellation_requested, request_id: request_id}}
    assert request_id == old.id
    assert Parlora.status(session).jobs[old.id].status == :submitted
    FakeBackend.complete(backend, old, "Obsolete order 123")
    assert_receive {:parlora_event, %Event{type: :stale_result, request_id: ^request_id}}
    refute_received {:context, _}

    MemoryAudio.inject(provider, :transcript_delta, %{
      speaker: :user,
      delta: " Actually order 124",
      start_ms: nil,
      end_ms: nil
    })

    assert_receive {:submitted, current}
    assert current.task_revision == old.task_revision + 1
    FakeBackend.complete(backend, current, "Current order 124")
    assert_receive {:context, %ContextUpdate{content: "Current order 124", delegation_id: nil}}
    close_and_observe(session, [channel, provider, backend])
  end

  defp boot(format, options) do
    channel_caps = %Parlora.Channel.Capabilities{
      input_formats: [format],
      output_formats: [format],
      full_duplex?: true
    }

    {:ok, session} =
      Parlora.start_session(
        audio_format: format,
        channel: {MemoryChannel, observer: self(), capabilities: channel_caps},
        provider: {ContractProvider, Keyword.put(options, :observer, self())},
        backend: {FakeBackend, observer: self()},
        context_policy: {OrderPolicy, []},
        event_sink: self()
      )

    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:adapter, :channel, channel}
    assert_receive {:adapter, :provider, provider}
    assert_receive {:adapter, :backend, backend}
    {session, channel, provider, backend}
  end

  defp close_and_observe(session, adapters) do
    monitors = Enum.map([session | adapters], &Process.monitor/1)
    assert :ok = Parlora.close(session)
    assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason})
  end

  defp await_frame(pid, expected, attempts \\ 100)
  defp await_frame(pid, expected, 0), do: assert(MemoryAudio.drain(pid) == [expected])

  defp await_frame(pid, expected, attempts) do
    case MemoryAudio.drain(pid) do
      [] ->
        Process.sleep(5)
        await_frame(pid, expected, attempts - 1)

      frames ->
        assert frames == [expected]
    end
  end
end
