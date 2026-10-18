defmodule Parlora.OutputSpaceTest do
  use ExUnit.Case, async: true

  alias Parlora.{
    AdapterInit,
    AudioFormat,
    AudioFrame,
    AudioPipeline,
    AudioQueue,
    Limits,
    OutputSpace
  }

  alias Parlora.Channels.Browser.Media
  alias Parlora.Channels.LocalAudio
  alias Parlora.TestSupport.MemoryAudio

  test "space before arm and consumption after arm each notify once for the required bytes" do
    queue = %AudioQueue{capacity: 960, bytes: 960}
    state = %{outbound: queue, epoch: 3, suppressed: false, output_waiter: nil}
    first = make_ref()
    second = make_ref()
    state = OutputSpace.arm(state, self(), first, 480, 3)
    state = OutputSpace.arm(state, self(), second, 480, 3)
    state = OutputSpace.notify(%{state | outbound: %{queue | bytes: 482}})
    refute_received {:parlora_output_space, _, _}
    state = OutputSpace.notify(%{state | outbound: %{queue | bytes: 480}})
    assert_receive {:parlora_output_space, _, ^second}
    assert state.output_waiter == nil
    OutputSpace.notify(state)
    refute_received {:parlora_output_space, _, _}
    third = make_ref()
    OutputSpace.arm(state, self(), third, 480, 3)
    assert_receive {:parlora_output_space, _, ^third}
  end

  test "wrong epochs and suppression cannot register or release a waiter" do
    state = %{outbound: %AudioQueue{}, epoch: 1, suppressed: false, output_waiter: nil}
    assert OutputSpace.arm(state, self(), make_ref(), 480, 0) == state
    stopped = %{state | suppressed: true}
    assert OutputSpace.arm(stopped, self(), make_ref(), 480, 1) == stopped
    stale = %{state | output_waiter: {self(), make_ref(), 480, 0}}
    assert OutputSpace.notify(stale) == stale
    refute_received {:parlora_output_space, _, _}
  end

  test "local audio exposes one-shot space hints and rejects old epochs or suppression" do
    init = init()

    pid =
      start_supervised!(%{
        id: :local_space,
        start: {LocalAudio, :start_link, [init, [device: :synthetic]]}
      })

    assert {:ok, _} = LocalAudio.capabilities(pid)
    ref = make_ref()
    assert :ok = LocalAudio.arm_output_space(pid, self(), ref, 480, 0)
    assert_receive {:parlora_output_space, ^pid, ^ref}
    refute_received {:parlora_output_space, ^pid, ^ref}
    assert :ok = LocalAudio.control(pid, "clear-space", {:clear_output, 1})
    old = make_ref()
    assert :ok = LocalAudio.arm_output_space(pid, self(), old, 480, 0)
    refute_received {:parlora_output_space, ^pid, ^old}
    assert :ok = LocalAudio.control(pid, "suppress-space", {:suppress_output, true})
    stopped = make_ref()
    assert :ok = LocalAudio.arm_output_space(pid, self(), stopped, 480, 1)
    refute_received {:parlora_output_space, ^pid, ^stopped}
    assert :sys.get_state(pid).output_waiter == nil
  end

  test "browser consumption wakes a blocked writer, while clear cancels its old waiter" do
    init = init()
    options = %{jitter_ms: 0, max_rtp_packets: 32, max_age_ms: 200, playback_buffer_ms: 0}
    state = %{init: init, media: Media.open(init, options)}
    on_exit(fn -> Media.close(state.media) end)
    frame = AudioFrame.pcm(:binary.copy(<<2, 0>>, 240), "space", 0)
    {:ok, queue} = AudioQueue.push(%AudioQueue{capacity: 480}, frame)
    ref = make_ref()
    media = OutputSpace.arm(%{state.media | outbound: queue}, self(), ref, 480, 0)
    {_packet, next} = Media.output(%{state | media: media}, 0)
    assert_receive {:parlora_output_space, _, ^ref}
    assert next.media.output_waiter == nil
    old = make_ref()
    media = OutputSpace.arm(%{next.media | outbound: queue}, self(), old, 480, 0)
    cleared = Media.clear(%{next | media: media}, 1)
    {_packet, cleared} = Media.output(cleared, 10_000)
    assert cleared.media.output_waiter == nil
    refute_received {:parlora_output_space, _, ^old}
  end

  test "pipeline wakes without its poll timer and rejects duplicate or pre-clear space hints" do
    init = init()
    provider_init = %{init | limits: %{init.limits | audio_queue_bytes: 33_600}}

    source =
      start_supervised!(%{
        id: :source,
        start: {MemoryAudio, :start_link, [provider_init, :provider, []]}
      })

    destination =
      start_supervised!(%{
        id: :destination,
        start: {MemoryAudio, :start_link, [init, :channel, [output_space: true]]}
      })

    {:ok, _} = MemoryAudio.capabilities(source)
    {:ok, _} = MemoryAudio.capabilities(destination)

    {:ok, state} =
      AudioPipeline.init(
        init: init,
        direction: :output,
        source: {MemoryAudio, source},
        destination: {MemoryAudio, destination},
        output_pacing: :channel
      )

    assert_receive :tick

    for i <- 0..39,
        do:
          :ok = MemoryAudio.audio(source, AudioFrame.pcm(:binary.copy(<<i, 0>>, 240), "burst", i))

    {:noreply, state} = AudioPipeline.handle_info(:tick, state)
    {:noreply, blocked} = AudioPipeline.handle_info(:tick, state)
    assert is_reference(blocked.space_ref)
    assert Enum.map(MemoryAudio.drain(destination), & &1.sequence) == Enum.to_list(0..19)
    assert_receive {:parlora_output_space, ^destination, ref} = hint
    assert ref == blocked.space_ref
    {:noreply, awake} = AudioPipeline.handle_info(hint, blocked)
    assert Process.read_timer(blocked.tick_timer) == false
    assert Enum.map(MemoryAudio.drain(destination), & &1.sequence) == Enum.to_list(20..39)
    assert {:noreply, ^awake} = AudioPipeline.handle_info(hint, awake)

    {:reply, :ok, cleared} =
      AudioPipeline.handle_call({:control, "clear", {:clear_output, :next}}, nil, blocked)

    assert cleared.space_ref == nil
    assert {:noreply, ^cleared} = AudioPipeline.handle_info(hint, cleared)

    assert {:noreply, ^blocked} =
             AudioPipeline.handle_info({:parlora_output_space, self(), ref}, blocked)

    {:reply, :ok, suppressed} =
      AudioPipeline.handle_call({:control, "stop", {:suppress_output, true}}, nil, cleared)

    assert suppressed.space_ref == nil
    assert {:noreply, ^suppressed} = AudioPipeline.handle_info(hint, suppressed)
    Process.cancel_timer(awake.tick_timer)
  end

  test "a clear or a successful write invalidates a previously queued blockage timeout" do
    since = System.monotonic_time(:microsecond)
    state = %{epoch: 4, blocked_since_us: since}
    timeout = {:backpressure_timeout, 4, since}
    assert {:stop, :normal, ^state} = AudioPipeline.handle_info(timeout, state)
    cleared = %{state | epoch: 5, blocked_since_us: nil}
    assert {:noreply, ^cleared} = AudioPipeline.handle_info(timeout, cleared)
    resumed = %{state | blocked_since_us: nil}
    assert {:noreply, ^resumed} = AudioPipeline.handle_info(timeout, resumed)
    reblocked = %{state | blocked_since_us: since + 1}
    assert {:noreply, ^reblocked} = AudioPipeline.handle_info(timeout, reblocked)
  end

  defp init do
    %AdapterInit{
      session_id: "space",
      adapter_id: "space",
      generation: 0,
      audio_format: %AudioFormat{},
      limits: %Limits{},
      event_sink: self()
    }
  end
end
