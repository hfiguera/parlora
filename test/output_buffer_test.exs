defmodule Parlora.OutputBufferTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioQueue, Event, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI

  defp init(limits \\ %Limits{}) do
    %AdapterInit{
      limits: limits,
      audio_format: %AudioFormat{},
      session_id: "buffer-test",
      adapter_id: "provider",
      generation: 0,
      event_sink: self()
    }
  end

  test "all captured overflow windows replay without losing or reordering PCM" do
    evidence = File.read!("docs/output-overflow-evidence.json") |> JSON.decode!()

    for window <- evidence["windows"] do
      events = Enum.reject(window["events"], &(&1["event"] == "tick"))
      first = hd(events)
      values = first["measurements"]

      initial_bytes =
        if first["event"] == "audio_read",
          do: values["queue_bytes"] + values["bytes"],
          else: values["queue_before_bytes"]

      initial = :binary.copy(<<0>>, initial_bytes)
      config = init()

      {:ok, {queue, sequence}} =
        OutputBuffer.push(
          OutputBuffer.new(config.limits),
          initial,
          config,
          0,
          first["elapsed_us"]
        )

      {queue, _sequence, received, read} =
        Enum.reduce(events, {queue, sequence, initial, <<>>}, fn event,
                                                                 {queue, seq, input, output} ->
          values = event["measurements"]
          now = event["elapsed_us"]

          if event["event"] == "audio_received" do
            pcm = :binary.copy(<<rem(seq, 255)>>, values["bytes"])
            assert {:ok, {queue, seq}} = OutputBuffer.push(queue, pcm, config, seq, now)
            assert queue.bytes <= config.limits.provider_audio_queue_bytes
            {queue, seq, input <> pcm, output}
          else
            budget = max(values["bytes"], config.limits.max_frame_bytes)
            assert {:ok, frames, queue} = OutputBuffer.read(queue, budget, config.limits, now)
            {queue, seq, input, output <> Enum.map_join(frames, & &1.data)}
          end
        end)

      {remaining, _queue} = AudioQueue.pop(queue, queue.capacity)
      assert read <> Enum.map_join(remaining, & &1.data) == received
    end
  end

  test "measured 300 ms burst fits independently of the 200 ms playback budget" do
    config = init()

    {:ok, {queue, seq}} =
      OutputBuffer.push(OutputBuffer.new(config.limits), pcm(200), config, 0, 0)

    {:ok, [_first, _second], queue} = OutputBuffer.read(queue, 960, config.limits, 6_565)
    assert {:ok, {queue, _seq}} = OutputBuffer.push(queue, pcm(100), config, seq, 13_924)
    assert queue.bytes == 13_440
    assert config.limits.audio_queue_bytes == 9_600

    {:ok, {old_queue, seq}} =
      OutputBuffer.push(%AudioQueue{capacity: 9_600}, pcm(180), config, 0, 0)

    assert {:error, %{code: :output_overflow}} =
             OutputBuffer.push(old_queue, pcm(100), config, seq, 13_924)
  end

  test "capacity rejects a whole chunk and age rejects retained audio at the deadline" do
    config = init()

    {:ok, {queue, seq}} =
      OutputBuffer.push(OutputBuffer.new(config.limits), pcm(700), config, 0, 0)

    assert {:error, %{code: :output_overflow}} = OutputBuffer.push(queue, pcm(10), config, seq, 1)

    assert {:ok, frames, _rest} =
             OutputBuffer.read(
               queue,
               config.limits.provider_audio_queue_bytes,
               config.limits,
               749_999
             )

    assert Enum.map_join(frames, & &1.data) == pcm(700)

    assert {:error, %{code: :output_stale}} =
             OutputBuffer.read(queue, 960, config.limits, 750_000)

    assert {:error, %{code: :output_stale}} = OutputBuffer.push(queue, <<>>, config, seq, 750_000)
  end

  test "provider read requests recovery instead of forwarding stale generated audio" do
    config = init()
    {:ok, state, _continuation} = OpenAI.init({config, [api_key: "test"], %{}})
    old = System.monotonic_time(:microsecond) - 750_001
    {:ok, {queue, _seq}} = OutputBuffer.push(state.inbound, pcm(100), config, 0, old)
    state = %{state | status: :ready, inbound: queue}

    assert {:reply, {:ok, []}, recovering} =
             OpenAI.handle_call({:read, 960}, nil, state)

    assert recovering.status == :recovering
    assert recovering.inbound.bytes == 0
    assert recovering.outbound.capacity == 9_600
    assert recovering.inbound.capacity == 33_600

    assert_receive {:parlora_event,
                    %Event{type: :audio_discontinuity, payload: %{dropped_bytes: 4_800}}}

    assert_receive {:parlora_event, %Event{type: :output_recovery_requested}}
    refute_received {:parlora_event, %Event{type: :failed}}
    refute_received {:parlora_event, %Event{type: :closed}}
  end

  defp pcm(ms), do: :binary.copy(<<1, 0>>, ms * 24)
end
