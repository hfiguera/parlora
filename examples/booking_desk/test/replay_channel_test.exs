defmodule BookingDesk.ReplayChannelTest do
  use ExUnit.Case, async: true
  alias BookingDesk.ReplayChannel
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Limits, Playout}

  test "continuous speech fills every tick across all partial sample boundaries" do
    source = pcm(480)

    for boundary <- 2..478//2 do
      <<head::binary-size(^boundary), middle::binary-size(480), tail::binary>> = source
      state = state() |> write(head) |> write(middle) |> write(tail)
      {first, state} = tick(state)
      {second, state} = tick(state)
      assert first <> second == source, "inserted silence at byte #{boundary}"
      assert byte_size(first) == 480
      assert byte_size(second) == 480
      assert drained?(state)
    end
  end

  test "a final partial tick preserves every sample and pads only its end" do
    source = pcm(470)
    <<head::binary-size(448), middle::binary-size(480), tail::binary>> = source
    state = state() |> write(head) |> write(middle) |> write(tail)
    {first, state} = tick(state)
    refute drained?(state)
    {last, state} = tick(state)
    assert first <> last == source <> :binary.copy(<<0>>, 20)
    assert drained?(state)
    {silence, _state} = tick(state)
    assert silence == :binary.copy(<<0>>, 480)
  end

  @tag timeout: 1_000
  test "a valid frame larger than one tick is paced without blocking" do
    source = pcm(480)
    state = state() |> write(source)
    {first, state} = tick(state)
    refute drained?(state)
    {last, state} = tick(state)
    assert first <> last == source
    assert drained?(state)
  end

  test "initial buffering keeps short speech queued until the bounded wait expires" do
    source = pcm(480)
    state = state() |> write(source)
    state = %{state | playout: Playout.new(120, state.output.capacity, [])}
    {silence, state} = tick(state)
    assert silence == :binary.copy(<<0>>, 480)
    assert state.output.bytes == byte_size(source)
    refute drained?(state)

    playout = %{state.playout | waiting_since_us: System.monotonic_time(:microsecond) - 121_000}
    {first, state} = tick(%{state | playout: playout})
    {last, state} = tick(state)
    assert first <> last == source
    assert drained?(state)
  end

  test "interruption clears staged speech and rejects the old playback epoch" do
    state = state() |> write(pcm(224)) |> write(pcm(240))
    {_first, state} = tick(state)
    refute drained?(state)
    assert state.output.bytes == 0

    {:reply, :ok, state} =
      ReplayChannel.handle_call({:control, "interrupt", {:clear_output, 1}}, nil, state)

    assert drained?(state)
    {silence, state} = tick(state)
    assert silence == :binary.copy(<<0>>, 480)
    old = AudioFrame.pcm(pcm(240), "assistant", 0, playback_epoch: 0)

    assert {:reply, {:error, %{code: :invalid_argument}}, ^state} =
             ReplayChannel.handle_call({:write, old}, nil, state)

    fresh = pcm(240)
    {played, _state} = state |> write(fresh, 1) |> tick()
    assert played == fresh
  end

  test "staged audio counts toward backpressure and quiet tails count as drained" do
    state = state(960) |> write(pcm(224)) |> write(pcm(240))
    {_first, state} = tick(state)
    state = write(state, pcm(240))
    frame = AudioFrame.pcm(pcm(17), "assistant", 0, playback_epoch: 0)

    assert {:reply, {:error, %{code: :backpressure}}, ^state} =
             ReplayChannel.handle_call({:write, frame}, nil, state)

    state = write(state, pcm(16))
    {second, state} = tick(state)
    {third, state} = tick(state)
    assert byte_size(second) == 480
    assert byte_size(third) == 480
    assert drained?(state)

    state = state() |> write(pcm(224)) |> write(:binary.copy(<<0>>, 480))
    {_first, state} = tick(state)
    assert drained?(state)
  end

  defp state(capacity \\ 9_600) do
    init = %AdapterInit{
      session_id: "replay-framing",
      adapter_id: "replay",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{audio_queue_bytes: capacity}
    }

    observer = %{pid: self(), credits: :atomics.new(2, [])}
    {:ok, state} = ReplayChannel.init({init, owner: self(), observer: observer})
    %{state | playout: %Playout{buffer_ms: 0}}
  end

  defp write(state, pcm, epoch \\ 0) do
    frame = AudioFrame.pcm(pcm, "assistant", 0, playback_epoch: epoch)
    {:reply, :ok, state} = ReplayChannel.handle_call({:write, frame}, nil, state)
    state
  end

  defp tick(state) do
    {:noreply, state} = ReplayChannel.handle_info(:tick, state)
    assert_receive {:parlora_audio, :input, _, _pcm}
    assert_receive {:parlora_audio, :output, _, pcm}
    :atomics.sub(state.observer.credits, 1, 2)
    {pcm, state}
  end

  defp drained?(state) do
    {:reply, drained, ^state} = ReplayChannel.handle_call(:output_drained, nil, state)
    drained
  end

  defp pcm(samples), do: for(n <- 1..samples, into: <<>>, do: <<1000 + n::signed-little-16>>)
end
