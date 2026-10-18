defmodule Parlora.AudioReadyTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, AudioPipeline, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI
  alias Parlora.TestSupport.MemoryAudio

  defp init do
    %AdapterInit{
      session_id: "ready",
      adapter_id: "ready",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }
  end

  test "provider handles arrival-before-arm, replaces arms and clears them on read and close" do
    {:ok, state, _} = OpenAI.init({init(), [api_key: "test"], %{}})
    state = %{state | status: :ready}
    first = make_ref()
    second = make_ref()
    {:reply, :ok, state} = OpenAI.handle_call({:arm_output_ready, self(), first}, nil, state)
    {:reply, :ok, state} = OpenAI.handle_call({:arm_output_ready, self(), second}, nil, state)
    assert state.audio_waiter == {self(), second}
    {:reply, {:ok, []}, state} = OpenAI.handle_call({:read, 960}, nil, state)
    assert state.audio_waiter == {self(), second}
    pcm = :binary.copy(<<1, 0>>, 240)

    {:ok, {queue, _}} =
      OutputBuffer.push(state.inbound, pcm, init(), 0, System.monotonic_time(:microsecond))

    state = %{state | inbound: queue}
    third = make_ref()
    {:reply, :ok, state} = OpenAI.handle_call({:arm_output_ready, self(), third}, nil, state)
    assert_receive {:parlora_audio_ready, source, ^third}
    assert source == self()
    assert state.audio_waiter == nil
    refute_received {:parlora_audio_ready, _, ^first}
    refute_received {:parlora_audio_ready, _, ^second}
    {:reply, {:ok, [_]}, state} = OpenAI.handle_call({:read, 960}, nil, state)
    {:reply, :ok, state} = OpenAI.handle_call({:arm_output_ready, self(), first}, nil, state)
    {:reply, :ok, closed} = OpenAI.handle_call({:close, "close", :cancel}, nil, state)
    assert closed.audio_waiter == nil
  end

  test "readiness replaces one timer, preserves PCM, and ignores duplicate or pre-clear hints" do
    {:ok, source} = MemoryAudio.start_link(init(), :provider, audio_ready: true)
    {:ok, destination} = MemoryAudio.start_link(init(), :channel, [])

    on_exit(fn ->
      for pid <- [source, destination], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, _} = MemoryAudio.capabilities(source)
    {:ok, _} = MemoryAudio.capabilities(destination)

    {:ok, state} =
      AudioPipeline.init(
        init: init(),
        direction: :output,
        source: {MemoryAudio, source},
        destination: {MemoryAudio, destination},
        output_pacing: :channel
      )

    assert_receive :tick
    {:noreply, armed} = AudioPipeline.handle_info(:tick, state)
    assert is_reference(armed.ready_ref)
    data = :binary.copy(<<2, 0>>, 240)
    :ok = MemoryAudio.audio(source, AudioFrame.pcm(data, "source", 0))
    assert_receive {:parlora_audio_ready, ^source, reference} = hint
    assert reference == armed.ready_ref
    {:noreply, awake} = AudioPipeline.handle_info(hint, armed)
    assert Process.read_timer(armed.tick_timer) == false
    assert MemoryAudio.drain(destination) |> Enum.map_join(& &1.data) == data
    assert is_reference(awake.ready_ref)
    assert awake.ready_ref != reference
    assert {:noreply, ^awake} = AudioPipeline.handle_info(hint, awake)
    assert {:noreply, ^awake} = AudioPipeline.handle_info({:tick, armed.tick_token}, awake)
    {:noreply, armed} = AudioPipeline.handle_info(:tick, awake)
    old = {:parlora_audio_ready, source, armed.ready_ref}

    {:reply, :ok, cleared} =
      AudioPipeline.handle_call({:control, "clear", {:clear_output, :next}}, nil, armed)

    assert cleared.epoch == 1
    assert cleared.ready_ref == nil
    assert {:noreply, ^cleared} = AudioPipeline.handle_info(old, cleared)
    {:noreply, armed} = AudioPipeline.handle_info(:tick, cleared)
    old = {:parlora_audio_ready, source, armed.ready_ref}

    assert {:noreply, ^armed} =
             AudioPipeline.handle_info({:parlora_audio_ready, self(), armed.ready_ref}, armed)

    {:reply, :ok, suppressed} =
      AudioPipeline.handle_call({:control, "suppress", {:suppress_output, true}}, nil, armed)

    assert suppressed.ready_ref == nil
    assert {:noreply, ^suppressed} = AudioPipeline.handle_info(old, suppressed)
    :ok = MemoryAudio.audio(source, AudioFrame.pcm(data, "source", 1))
    {:noreply, suppressed} = AudioPipeline.handle_info(:tick, suppressed)
    assert suppressed.ready_ref == nil
    assert MemoryAudio.drain(destination) == []
    Process.cancel_timer(suppressed.tick_timer)
  end
end
