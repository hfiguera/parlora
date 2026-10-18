defmodule Parlora.SubstitutionTest do
  # Real device callbacks and backend deadlines need isolation from replay load.
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Parlora.{AudioFormat, AudioFrame, Event}
  alias Parlora.Backends.Jido, as: JidoBackend
  alias Parlora.Backends.Legion, as: LegionBackend
  alias Parlora.Backends.Sagents, as: SagentsBackend
  alias Parlora.Channels.{Browser, LocalAudio, Telnyx, Twilio}

  alias Parlora.TestSupport.{
    BrowserPeer,
    ContractProvider,
    FakeBackend,
    LegionModel,
    LookupAgent,
    MemoryAudio,
    MemoryChannel,
    OrderPolicy,
    SagentsModel,
    TelnyxPeer
  }

  for channel <- [MemoryChannel, LocalAudio, Browser, Twilio, Telnyx],
      backend <- [FakeBackend, JidoBackend, SagentsBackend, LegionBackend] do
    @channel channel
    @backend backend
    test "correction and audio with #{inspect(channel)} and #{inspect(backend)}" do
      start_supervised!({Jido, name: Parlora.SubstitutionJido})

      observer = self()
      format = if @channel in [Twilio, Telnyx], do: AudioFormat.pcmu(), else: %AudioFormat{}

      backend_options =
        cond do
          @backend == FakeBackend ->
            [observer: self()]

          @backend == LegionBackend ->
            options = LegionModel.options(observer)
            execution = options[:execution]

            Keyword.put(options, :execution, fn request ->
              execution.(%{request | input: Map.put(request.input, :gate, observer)})
            end)

          @backend == SagentsBackend ->
            options = SagentsModel.options(observer)
            agent = options[:agent]

            Keyword.put(options, :agent, fn request ->
              agent.(%{request | input: Map.put(request.input, :gate, observer)})
            end)

          true ->
            [
              agent: LookupAgent,
              signal: fn request ->
                Jido.Signal.new!(
                  "parlora.request",
                  %{input: Map.put(request.input, :gate, observer)},
                  %{source: "/test"}
                )
              end,
              agent_options: [jido: Parlora.SubstitutionJido],
              result: fn %{status: status, result: result} ->
                %{
                  status: status,
                  facts: result,
                  summary: "Order #{result.order} arrives tomorrow"
                }
              end
            ]
        end

      {:ok, pid} =
        Parlora.start_session(
          channel: {@channel, channel_options()},
          audio_format: format,
          provider: {ContractProvider, observer: self()},
          backend: {@backend, backend_options},
          context_policy: {OrderPolicy, []},
          event_sink: self()
        )

      on_exit(fn -> if Process.alive?(pid), do: Parlora.close(pid) end)

      if @channel == Browser do
        assert_receive {:parlora_browser, channel, :attached},
                       %Parlora.Limits{}.startup_timeout_ms

        BrowserPeer.connect(channel)
      end

      if @channel == Twilio do
        assert_receive {:parlora_twilio, channel, :attached}
        start_twilio(channel)
      end

      if @channel == Telnyx do
        assert_receive {:parlora_telnyx, channel, :attached}

        Enum.each(
          TelnyxPeer.handshake(),
          &Telnyx.receive_message(channel, &1)
        )
      end

      assert_receive {:adapter, :provider, provider}

      assert_receive {:parlora_event, %Event{source: :session, type: :ready}},
                     %Parlora.Limits{}.startup_timeout_ms

      MemoryAudio.inject(provider, :delegation_requested, %{
        id: "lookup",
        target: :client,
        offset_ms: 0
      })

      transcript(provider, "order 123")
      assert_receive {:parlora_event, %Event{type: :task_submitted, payload: %{request: first}}}
      transcript(provider, " actually order 124")
      assert_receive {:parlora_event, %Event{type: :task_submitted, payload: %{request: second}}}
      assert second.task_revision == 2
      assert second.task_id == first.task_id
      state = :sys.get_state(pid)
      {_module, channel} = state.adapters.channel

      if @channel == MemoryChannel do
        :ok = MemoryAudio.audio(channel, AudioFrame.pcm(:binary.copy(<<0, 0>>, 240), "mic", 0))
      end

      if @channel == Twilio do
        :ok =
          Twilio.receive_message(channel, %{
            "event" => "media",
            "sequenceNumber" => "2",
            "streamSid" => "MZ33333333333333333333333333333333",
            "media" => %{
              "track" => "inbound",
              "chunk" => "1",
              "timestamp" => "0",
              "payload" => Base.encode64(AudioFormat.silence(format, 10))
            }
          })
      end

      if @channel == Telnyx do
        :ok =
          Telnyx.receive_message(
            channel,
            TelnyxPeer.media(AudioFormat.silence(format, 20))
          )
      end

      :ok =
        MemoryAudio.audio(
          provider,
          AudioFrame.new(AudioFormat.silence(format, 10), format, "voice", 0)
        )

      assert {:error, %{code: :unsupported}} = Parlora.control(pid, {:unknown, true}, "bad")
      assert {:error, %{code: :unsupported}} = Parlora.control(pid, {:unknown, true}, "bad")

      if @backend == FakeBackend do
        {_module, backend} = state.adapters.backend
        :ok = FakeBackend.complete(backend, first, "Obsolete answer")
        :ok = FakeBackend.complete(backend, second, "Order 124 arrives tomorrow")
      else
        assert_receive {:lookup_waiting, "123", old_worker}
        assert_receive {:lookup_waiting, "124", current_worker}
        send(current_worker, :finish)
        send(old_worker, :finish)
      end

      assert_receive {:context, %{content: "Order 124 arrives tomorrow", task_revision: 2}}
      assert_receive {:parlora_event, %Event{type: :stale_result}}
      refute_receive {:context, %{task_revision: 1}}, 30
      Process.sleep(40)
      assert MemoryAudio.drain(provider) != []
      assert :ok = Parlora.control(pid, {:clear_output, :next})
      assert :ok = Parlora.close(pid, :finish)
      assert_receive {:parlora_event, %Event{source: :session, type: :closed}}
    end
  end

  defp channel_options do
    [
      call_control_id: "call",
      call_session_id: "session",
      device: :synthetic,
      signaling: self(),
      transport: self(),
      account_sid: "AC11111111111111111111111111111111",
      call_sid: "CA22222222222222222222222222222222"
    ]
  end

  defp start_twilio(channel) do
    :ok =
      Twilio.receive_message(channel, %{
        "event" => "connected",
        "protocol" => "Call",
        "version" => "1.0.0"
      })

    :ok =
      Twilio.receive_message(channel, %{
        "event" => "start",
        "sequenceNumber" => "1",
        "streamSid" => "MZ33333333333333333333333333333333",
        "start" => %{
          "accountSid" => "AC11111111111111111111111111111111",
          "callSid" => "CA22222222222222222222222222222222",
          "streamSid" => "MZ33333333333333333333333333333333",
          "tracks" => ["inbound"],
          "mediaFormat" => %{
            "encoding" => "audio/x-mulaw",
            "sampleRate" => 8_000,
            "channels" => 1
          }
        }
      })
  end

  defp transcript(provider, text),
    do:
      MemoryAudio.inject(provider, :transcript_delta, %{
        speaker: :user,
        delta: text,
        start_ms: 0,
        end_ms: 10
      })
end
