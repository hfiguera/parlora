defmodule Parlora.PlaybackPressureTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}
  alias Parlora.Channels.{Browser, LocalAudio}
  alias Parlora.Providers.OpenAI
  alias Parlora.TestSupport.BrowserRecoveryReplay

  test "recorded recovery burst survives every millisecond browser clock phase" do
    results = BrowserRecoveryReplay.run()
    fixed = Enum.filter(results, &(&1.policy == :pressure))
    assert Enum.map(fixed, & &1.browser_tick_phase_us) == Enum.to_list(0..9_000//1_000)
    assert Enum.all?(fixed, &(&1.failure == nil and &1.played_bytes == 52_800))
    assert Enum.all?(fixed, &(&1.first_source_play_us < 150_000))
  end

  test "provider reports its actual receive queue capacity without consuming audio" do
    {:ok, queue} = AudioQueue.push(%AudioQueue{capacity: 1_920}, frame())
    state = %{status: :ready, inbound: queue}

    assert {:reply, {:ok, %{queued_bytes: 480, capacity_bytes: 1_920}}, ^state} =
             OpenAI.handle_call(:output_buffer_status, nil, state)
  end

  test "pressure releases only current recovery, preserves samples and cannot cross clear" do
    {:ok, queue} = AudioQueue.push(%AudioQueue{}, frame())
    playout = %{Playout.new(120, queue.capacity) | recovering?: true}
    local = %{status: :ready, epoch: 2, playout: playout}
    browser = %{status: :ready, media: %{epoch: 2, playout: playout}}

    for {module, state} <- [{LocalAudio, local}, {Browser, browser}] do
      assert {:reply, :ok, ^state} =
               module.handle_call({:release_output_recovery, 1}, nil, state)

      assert {:reply, :ok, next} =
               module.handle_call({:release_output_recovery, 2}, nil, state)

      released = Map.get(next, :media, next).playout
      {pcm, remaining, released} = Playout.take(released, queue, 480, 0)
      assert pcm == frame().data
      assert remaining.bytes == 0
      assert released.source_bytes == 480
      assert Playout.release_recovery(released) == released

      reset = Playout.reset(released)
      assert Playout.release_recovery(reset) == reset
      {_silence, held, _state} = Playout.take(reset, queue, 480, 0)
      assert held == queue
    end
  end

  defp frame, do: AudioFrame.pcm(:binary.copy(<<42, 0>>, 240), "pressure", 0)
end
