defmodule Parlora.StartSessionOptionsTest do
  use ExUnit.Case, async: true

  alias Parlora.{AudioFormat, Error, Event}
  alias Parlora.Channel.Capabilities, as: ChannelCapabilities
  alias Parlora.Providers.{Gemini, Grok, OpenAI, Phonic}
  alias Parlora.TestSupport.{FakeBackend, MemoryChannel, MemoryProvider, OrderPolicy}

  defmodule ObservedProvider do
    use Parlora.TestSupport.MemoryAudio, role: :provider

    @impl true
    def audio_limits(format) do
      send(self(), {:audio_limits, format})
      OpenAI.audio_limits(format)
    end
  end

  setup do
    options = [
      channel: {MemoryChannel, observer: self()},
      provider: {ObservedProvider, observer: self()},
      backend: {FakeBackend, observer: self()},
      context_policy: {OrderPolicy, []},
      event_sink: self()
    ]

    %{options: options}
  end

  test "invalid audio formats are rejected before provider defaults or adapters run", %{
    options: options
  } do
    for format <- [
          :invalid,
          nil,
          %{},
          Map.from_struct(%AudioFormat{}),
          %AudioFormat{sample_rate_hz: 0},
          %AudioFormat{channels: 2},
          %AudioFormat{sample_format: :f32le}
        ] do
      assert {:error, %Error{code: :invalid_argument}} =
               Parlora.start_session(Keyword.put(options, :audio_format, format))
    end

    refute_received {:audio_limits, _format}
    refute_received {:adapter, _role, _pid}
  end

  test "invalid transcript retention is rejected before provider callbacks", %{options: options} do
    for mode <- [:invalid, nil, true, "rolling", []] do
      assert {:error, %Error{code: :invalid_argument}} =
               Parlora.start_session(Keyword.put(options, :transcript_retention, mode))
    end

    refute_received {:audio_limits, _format}
    refute_received {:adapter, _role, _pid}
  end

  test "malformed limits are rejected before provider defaults or adapters run", %{
    options: options
  } do
    for limits <- [
          :invalid,
          nil,
          %{},
          42,
          [:max_jobs],
          [{"max_jobs", 4}],
          [{:max_jobs, 4, :extra}],
          [{:max_jobs, 4} | :invalid]
        ] do
      assert {:error, %Error{code: :invalid_argument}} =
               Parlora.start_session(Keyword.put(options, :limits, limits))
    end

    refute_received {:audio_limits, _format}
    refute_received {:adapter, _role, _pid}
  end

  test "built-in providers return validation errors for malformed startup audio options", %{
    options: options
  } do
    for provider <- [OpenAI, Gemini, Grok, Phonic],
        invalid <- [[audio_format: :invalid], [limits: :invalid]] do
      options = options |> Keyword.put(:provider, {provider, []}) |> Keyword.merge(invalid)
      assert {:error, %Error{code: :invalid_argument}} = Parlora.start_session(options)
    end

    refute_received {:adapter, _role, _pid}
  end

  test "limit values and relationships are still validated after provider defaults are merged", %{
    options: options
  } do
    for limits <- [[max_jobs: 0], [unknown: 1], [max_frame_bytes: 2], [audio_queue_bytes: 10]] do
      assert {:error, %Error{code: :invalid_argument}} =
               Parlora.start_session(Keyword.put(options, :limits, limits))

      assert_received {:audio_limits, %AudioFormat{}}
    end

    refute_received {:adapter, _role, _pid}
  end

  test "valid formats retain provider defaults and explicit overrides", %{options: options} do
    for format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      queue_bytes = AudioFormat.bytes_for_ms(format, 1_000)

      channel_caps = %{
        ChannelCapabilities.buffered_pcm()
        | input_formats: [format],
          output_formats: [format]
      }

      provider_caps = %{OpenAI.Protocol.capabilities() | audio_formats: [format]}

      for overrides <- [[], [provider_audio_queue_bytes: queue_bytes]],
          provider <- [ObservedProvider, MemoryProvider] do
        options =
          Keyword.merge(options,
            channel: {MemoryChannel, observer: self(), capabilities: channel_caps},
            provider: {provider, observer: self(), capabilities: provider_caps},
            audio_format: format,
            limits: overrides
          )

        {:ok, session} = Parlora.start_session(options)
        on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
        assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
        assert_receive {:adapter, :provider, adapter}

        limits = :sys.get_state(adapter).init.limits

        duration = if provider == ObservedProvider, do: 2_000, else: 700
        expected = Keyword.get(overrides, :provider_audio_queue_bytes)

        assert limits.provider_audio_queue_bytes ==
                 (expected || AudioFormat.bytes_for_ms(format, duration))

        if provider == ObservedProvider, do: assert_received({:audio_limits, ^format})
        reference = Process.monitor(session)
        assert :ok = Parlora.close(session)
        assert_receive {:DOWN, ^reference, :process, ^session, :normal}
      end
    end
  end

  test "frame limits are checked against the merged provider capacity", %{options: options} do
    options = Keyword.put(options, :limits, audio_queue_bytes: 48_000, max_frame_bytes: 48_000)
    {:ok, session} = Parlora.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: Parlora.close(session) end)
    assert_receive {:parlora_event, %Event{source: :session, type: :ready}}
    assert_received {:audio_limits, %AudioFormat{}}
    assert :ok = Parlora.close(session)
  end
end
