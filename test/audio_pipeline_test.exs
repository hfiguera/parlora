defmodule Parlora.AudioPipelineTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioPipeline, Limits}
  alias Parlora.TestSupport.MemoryAudio

  setup do
    init = %AdapterInit{
      limits: %Limits{},
      audio_format: %AudioFormat{},
      session_id: "pipeline-test",
      adapter_id: "channel",
      generation: 0,
      event_sink: self()
    }

    provider_init = %{
      init
      | limits: %{init.limits | audio_queue_bytes: init.limits.provider_audio_queue_bytes}
    }

    source = memory(provider_init, :provider)
    destination = memory(init, :channel)
    # Drive ticks explicitly to test clear/suppress races without wall-clock sleeps.
    {:ok, state} =
      AudioPipeline.init(
        init: init,
        direction: :output,
        source: {MemoryAudio, source},
        destination: {MemoryAudio, destination}
      )

    assert_receive :tick
    {:ok, state: state, source: source, destination: destination}
  end

  test "clear drains more than the playback budget, pending frames and destination", context do
    fill(context.source, "old")
    {:noreply, state} = AudioPipeline.handle_info(:tick, context.state)
    assert state.pending != []

    assert {:reply, :ok, state} =
             AudioPipeline.handle_call({:control, "clear", {:clear_output, :next}}, nil, state)

    assert state.pending == []
    assert state.epoch == 1

    assert {:ok, []} =
             MemoryAudio.read_audio(
               context.source,
               context.state.init.limits.provider_audio_queue_bytes
             )

    assert MemoryAudio.drain(context.destination) == []

    fresh = AudioFrame.pcm(:binary.copy(<<2, 0>>, 240), "fresh", 31)
    :ok = MemoryAudio.audio(context.source, fresh)
    {:noreply, _state} = AudioPipeline.handle_info(:tick, state)
    assert [%{stream_id: "fresh", playback_epoch: 1}] = MemoryAudio.drain(context.destination)
  end

  test "channel-paced output refills promptly but retains frames on bounded backpressure",
       context do
    fill(context.source, "burst")
    state = %{context.state | output_pacing: :channel}
    deadline = System.monotonic_time(:microsecond) + 1_000_000
    {:noreply, state} = AudioPipeline.handle_info(:tick, %{state | deadline: deadline})
    assert state.deadline == deadline + 1_000

    {:noreply, blocked} = AudioPipeline.handle_info(:tick, state)
    assert blocked.blocked_since_us != nil
    assert Enum.map(blocked.pending, & &1.sequence) == [20, 21]
    assert blocked.deadline == state.deadline + 10_000
    {:noreply, still_blocked} = AudioPipeline.handle_info(:tick, blocked)
    assert still_blocked.pending == blocked.pending
    assert Enum.map(MemoryAudio.drain(context.destination), & &1.sequence) == Enum.to_list(0..19)
    {:noreply, resumed} = AudioPipeline.handle_info(:tick, blocked)
    assert resumed.blocked_since_us == nil
    assert Enum.map(MemoryAudio.drain(context.destination), & &1.sequence) == Enum.to_list(20..39)
    assert resumed.pending == []
  end

  test "suppression drains bursts and resume discards everything accumulated while suppressed",
       context do
    fill(context.source, "before")

    {:reply, :ok, state} =
      AudioPipeline.handle_call({:control, "stop", {:suppress_output, true}}, nil, context.state)

    assert {:ok, []} =
             MemoryAudio.read_audio(
               context.source,
               context.state.init.limits.provider_audio_queue_bytes
             )

    fill(context.source, "during")
    {:noreply, state} = AudioPipeline.handle_info(:tick, state)

    assert {:ok, []} =
             MemoryAudio.read_audio(
               context.source,
               context.state.init.limits.provider_audio_queue_bytes
             )

    assert MemoryAudio.drain(context.destination) == []

    fill(context.source, "just-before-resume")

    {:reply, :ok, state} =
      AudioPipeline.handle_call({:control, "resume", {:suppress_output, false}}, nil, state)

    assert {:ok, []} =
             MemoryAudio.read_audio(
               context.source,
               context.state.init.limits.provider_audio_queue_bytes
             )

    fresh = AudioFrame.pcm(:binary.copy(<<2, 0>>, 240), "fresh", 31)
    :ok = MemoryAudio.audio(context.source, fresh)
    {:noreply, _state} = AudioPipeline.handle_info(:tick, state)
    assert [%{stream_id: "fresh"}] = MemoryAudio.drain(context.destination)
  end

  test "only channel-paced output under upstream pressure sends a recovery hint", context do
    fill(context.source, "burst")

    for index <- 0..19 do
      frame = AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "full", index, playback_epoch: 0)
      :ok = MemoryAudio.write_audio(context.destination, frame)
    end

    {:noreply, _state} = AudioPipeline.handle_info(:tick, context.state)
    assert :sys.get_state(context.destination).recovery_release_epoch == nil

    paced = %{context.state | output_pacing: :channel}
    {:noreply, _state} = AudioPipeline.handle_info(:tick, paced)
    assert :sys.get_state(context.destination).recovery_release_epoch == 0

    :sys.replace_state(context.destination, &%{&1 | recovery_release_epoch: nil})
    :sys.replace_state(context.source, &%{&1 | options: [pressure_status: false]})
    {:noreply, _state} = AudioPipeline.handle_info(:tick, paced)
    assert :sys.get_state(context.destination).recovery_release_epoch == nil

    :sys.replace_state(
      context.source,
      &%{&1 | options: [], inbound: %{&1.inbound | capacity: 33_600}}
    )

    {:ok, _frames} = MemoryAudio.read_audio(context.source, 33_600)
    :ok = MemoryAudio.audio(context.source, AudioFrame.pcm(:binary.copy(<<2, 0>>, 240), "low", 0))
    {:noreply, _state} = AudioPipeline.handle_info(:tick, paced)
    assert :sys.get_state(context.destination).recovery_release_epoch == nil
  end

  test "a transfer turn yields after 20 frames even when both queues have more room", context do
    fill(context.source, "fairness")

    :sys.replace_state(context.destination, fn state ->
      %{state | outbound: %{state.outbound | capacity: 33_600}}
    end)

    paced = %{context.state | output_pacing: :channel}
    {:noreply, next} = AudioPipeline.handle_info(:tick, paced)
    assert Enum.map(MemoryAudio.drain(context.destination), & &1.sequence) == Enum.to_list(0..19)
    assert next.blocked_since_us == nil
    assert next.pending == []
    {:ok, remaining} = MemoryAudio.read_audio(context.source, 33_600)
    assert Enum.map(remaining, & &1.sequence) == Enum.to_list(20..69)
    Process.cancel_timer(next.tick_timer)
  end

  test "a blocked consumer stops at the deadline without discarding pending PCM", context do
    fill(context.source, "timeout")
    paced = %{context.state | output_pacing: :channel}
    {:noreply, full} = AudioPipeline.handle_info(:tick, paced)
    {:noreply, blocked} = AudioPipeline.handle_info(:tick, full)
    since = System.monotonic_time(:microsecond) - 500_001
    {:noreply, expired} = AudioPipeline.handle_info(:tick, %{blocked | blocked_since_us: since})
    assert expired.pending == blocked.pending
    assert_receive {:backpressure_timeout, 0, ^since} = timeout
    assert {:stop, :normal, ^expired} = AudioPipeline.handle_info(timeout, expired)
    Process.cancel_timer(expired.tick_timer)
  end

  defp memory(init, role) do
    pid = start_supervised!(%{id: role, start: {MemoryAudio, :start_link, [init, role, []]}})
    # Round trip ensures its initial readiness message has been handled.
    {:ok, _capabilities} = MemoryAudio.capabilities(pid)
    pid
  end

  defp fill(source, stream) do
    for index <- 0..69 do
      :ok = MemoryAudio.audio(source, AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), stream, index))
    end
  end
end
