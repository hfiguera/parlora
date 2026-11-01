defmodule BookingDesk.GreetingTest do
  use ExUnit.Case, async: true
  alias BookingDesk.Greeting

  test "continuous silent PCM permits the caller but buffered audible speech does not" do
    alias Parlora.{AudioFrame, AudioQueue}
    silent = AudioFrame.pcm(:binary.copy(<<0>>, 480), "greeting-test", 0)
    voice = AudioFrame.pcm(:binary.copy(<<1000::signed-little-16>>, 240), "greeting-test", 1)
    {:ok, queue} = AudioQueue.push(%AudioQueue{}, silent)
    assert queue.bytes > 0
    assert BookingDesk.ReplayChannel.output_drained?(queue)
    {:ok, pending} = AudioQueue.push(queue, voice)
    refute BookingDesk.ReplayChannel.output_drained?(pending)
  end

  test "a connection or context acknowledgment cannot start the caller without played assistant audio" do
    observation = %{
      text: "Cedarwood Family Clinic, this is Ava. How can I help?",
      heard_audio: true,
      output_drained: true,
      quiet_ms: 1100,
      speech: :idle
    }

    assert Greeting.ready?(observation)

    for changed <- [
          %{observation | heard_audio: false},
          %{observation | output_drained: false},
          %{observation | text: ""},
          %{observation | speech: :speaking},
          %{observation | quiet_ms: 999}
        ] do
      refute Greeting.ready?(changed)
    end

    assert Greeting.ready?(%{observation | speech: :unknown})
  end

  test "opening is application context, never a fabricated caller transcript or backend request" do
    first = Greeting.update(3)
    second = Greeting.update(3)
    assert first.kind == :speakable
    assert first.provider_generation == 3
    assert first.delegation_id == nil
    assert first.task_id == nil
    assert first.id != second.id
    assert first.content =~ "The caller has not spoken yet"
  end
end
