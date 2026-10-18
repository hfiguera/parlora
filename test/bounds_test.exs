defmodule Parlora.BoundsTest do
  use ExUnit.Case, async: true
  alias Parlora.{AudioFrame, AudioQueue, CommandLog, Limits}

  test "audio admission is whole-frame and memory stays bounded under overload" do
    frame = AudioFrame.pcm(:binary.copy(<<0, 0>>, 240), "stream", 0)
    queue = %AudioQueue{capacity: 960}
    {:ok, queue} = AudioQueue.push(queue, frame)
    {:ok, queue} = AudioQueue.push(queue, %{frame | sequence: 1})

    for _attempt <- 1..1_000 do
      assert {:error, %{code: :backpressure}} = AudioQueue.push(queue, frame)
    end

    assert queue.bytes == 960
    {[first], queue} = AudioQueue.pop(queue, 480)
    assert first.sequence == 0
    {[second], queue} = AudioQueue.pop(queue, 480)
    assert second.sequence == 1
    assert queue.bytes == 0
  end

  test "bounded command records retain duplicate identity and reject conflicts" do
    {:new, log} = CommandLog.admit(%CommandLog{limit: 1}, "one", :mute)
    assert {:duplicate, ^log} = CommandLog.admit(log, "one", :mute)
    assert {:error, %{code: :invalid_argument}} = CommandLog.admit(log, "one", :unmute)
    assert {:error, %{code: :backpressure}} = CommandLog.admit(log, "two", :mute)
  end

  test "invalid limits cannot create unbounded queues or unreadable frames" do
    assert {:error, _error} = Limits.new(max_jobs: 0)
    assert {:error, _error} = Limits.new(audio_queue_bytes: 10)
    assert {:error, _error} = Limits.new(max_frame_bytes: 2)
    assert {:error, _error} = Limits.new(provider_audio_queue_bytes: 480)
    assert {:error, _error} = Limits.new(provider_audio_queue_bytes: 24_001)
    assert {:error, _error} = Limits.new(provider_audio_max_age_ms: 0)
    assert {:error, _error} = Limits.new(unknown: 1)
  end
end
