defmodule Parlora.PlayoutStarvationRegressionTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, Playout}

  setup do
    evidence = File.read!("validation/pcm-overflow/starvation-evidence.json") |> Jason.decode!()
    %{events: evidence["events"]}
  end

  test "recorded delivery and playout timings reproduce all three starvation gaps", %{
    events: events
  } do
    {_queue, playout} = replay(events, true)
    assert playout.starvations == 3
  end

  test "the same playout timings have no starvation with regular incoming frames", %{
    events: events
  } do
    first_frame = Enum.find(events, &(&1["kind"] == "frame"))["at_us"]
    last = List.last(events)["at_us"]

    frames =
      for at <- first_frame..last//10_000,
          do: %{"kind" => "frame", "at_us" => at, "bytes" => 480}

    calls = Enum.filter(events, &(&1["kind"] == "playout"))
    {_queue, playout} = replay(Enum.sort_by(frames ++ calls, & &1["at_us"]), false)
    assert playout.source_bytes > 0
    assert playout.starvations == 0
  end

  defp replay(events, verify?) do
    Enum.reduce(events, {%AudioQueue{}, %Playout{}}, fn event, {queue, state} ->
      case event["kind"] do
        "frame" ->
          frame = AudioFrame.pcm(:binary.copy(<<1, 0>>, div(event["bytes"], 2)), "replay", 0)
          assert {:ok, queue} = AudioQueue.push(queue, frame)
          {queue, state}

        "playout" ->
          {_pcm, queue, next} = Playout.take(state, queue, 960, event["at_us"])
          verify(verify?, event, queue, state, next)
          {queue, next}

        _provider_observation ->
          {queue, state}
      end
    end)
  end

  defp verify(false, _event, _queue, _state, _next), do: :ok

  defp verify(true, event, queue, state, next) do
    assert queue.bytes == event["queue_bytes"]
    assert next.source_bytes - state.source_bytes == event["source_bytes"]
    assert next.silence_bytes - state.silence_bytes == event["silence_bytes"]
  end
end
