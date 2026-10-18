defmodule Parlora.LocalAudioTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Event, ID, Limits}
  alias Parlora.Channels.LocalAudio
  alias Parlora.Native.{Device, Resampler}

  defp open do
    init = %AdapterInit{
      session_id: ID.new(),
      adapter_id: ID.new(),
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    {:ok, pid} = LocalAudio.start_link(init, device: :synthetic)
    assert_receive {:parlora_event, %Event{type: :ready}}, init.limits.startup_timeout_ms
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "integrated capture and playback use bounded PCM conversion and report handoff" do
    pid = open()
    assert {:ok, caps} = LocalAudio.capabilities(pid)
    assert caps.playback_evidence == [:queue, :handoff]
    assert {:error, %{code: :invalid_argument}} = LocalAudio.read_audio(pid, 1)
    Process.sleep(30)
    assert {:ok, [frame | _rest]} = LocalAudio.read_audio(pid, 960)
    assert frame.format == %AudioFormat{}
    assert frame.duration_us == 10_000
    assert :ok = LocalAudio.write_audio(pid, %{frame | playback_epoch: 0})
    assert_receive {:parlora_event, %Event{type: :playback_observed, payload: %{stage: :queued}}}

    assert_receive {:parlora_event,
                    %Event{type: :playback_observed, payload: %{stage: :handed_off}}}
  end

  test "clear adopts a native epoch and old writes are rejected, capture continues on suppression" do
    pid = open()
    frame = AudioFrame.pcm(:binary.copy(<<1, 0>>, 240), "test", 0, playback_epoch: 0)
    assert :ok = LocalAudio.write_audio(pid, frame)
    assert :ok = LocalAudio.control(pid, "clear", {:clear_output, 1})

    assert_receive {:parlora_event,
                    %Event{
                      type: :control_completed,
                      payload: %{epoch: 1, scope: :parlora_buffers}
                    }}

    assert LocalAudio.observations(pid).observed_epoch == 1
    assert {:error, %{code: :invalid_argument}} = LocalAudio.write_audio(pid, frame)
    assert :ok = LocalAudio.control(pid, "clear", {:clear_output, 1})
    assert :ok = LocalAudio.control(pid, "suppress", {:suppress_output, true})
    Process.sleep(30)
    assert {:ok, [_frame | _rest]} = LocalAudio.read_audio(pid, 960)
    assert :ok = LocalAudio.control(pid, "resume", {:suppress_output, false})
    assert :ok = LocalAudio.write_audio(pid, %{frame | playback_epoch: 1})
  end

  test "native channel exposes learned targets and never learns suppressed or stale frames" do
    pid = open()

    frame =
      AudioFrame.pcm(:binary.copy(<<1, 0>>, 480), "provider", 0,
        playback_epoch: 0,
        clock: :local_monotonic,
        timestamp_us: 0
      )

    for i <- 0..4, do: assert(:ok == LocalAudio.write_audio(pid, %{frame | sequence: i}))

    for i <- 5..9,
        do:
          assert(
            :ok == LocalAudio.write_audio(pid, %{frame | sequence: i, timestamp_us: 270_000})
          )

    stats = LocalAudio.observations(pid)
    assert stats.playback_buffering == :adaptive
    assert stats.playback_target_ms == 190
    assert stats.recovery_buffer_ms == 120
    assert :ok = LocalAudio.control(pid, "clear", {:clear_output, 1})
    assert LocalAudio.observations(pid).playback_target_ms == 190
    assert :sys.get_state(pid).playout.target.group == nil
    assert :ok = LocalAudio.control(pid, "suppress", {:suppress_output, true})
    assert :ok = LocalAudio.write_audio(pid, %{frame | playback_epoch: 1, timestamp_us: 870_000})
    assert :sys.get_state(pid).playout.target.group == nil
    assert {:error, %{code: :invalid_argument}} = LocalAudio.write_audio(pid, frame)
    assert LocalAudio.observations(pid).playback_target_ms == 190
  end

  test "resampler reset removes old filter contents" do
    {:ok, ref} = Resampler.new(24_000, 48_000, 1, 2, 240)
    {:ok, _audio, _frames} = Resampler.process(ref, :binary.copy(<<0, 32>>, 240))
    assert :ok = Resampler.reset(ref)

    for _block <- 1..4 do
      {:ok, output, _frames} = Resampler.process(ref, :binary.copy(<<0, 0>>, 240))
      assert output == :binary.copy(<<0>>, byte_size(output))
    end

    assert :ok = Resampler.close(ref)
  end

  test "native owner death stops callbacks even with a retained resource" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, ref} = Device.open_test(4_800)
        send(parent, {:resource, ref})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:resource, resource}
    send(owner, :stop)
    Process.sleep(40)
    assert Device.stats(resource).stopped
    before = Device.stats(resource).captured
    Process.sleep(20)
    assert Device.stats(resource).captured == before
  end

  test "repeated close releases native streams even while callers retain resource references" do
    for _iteration <- 1..3 do
      pid = open()
      resource = :sys.get_state(pid).device
      assert :ok = LocalAudio.close(pid, ID.new(), :test)
      assert_receive {:parlora_event, %Event{type: :closed}}
      assert Device.stats(resource).stopped
      GenServer.stop(pid)
    end
  end

  test "malformed native calls fail without damaging the resource" do
    {:ok, converter} = Resampler.new(24_000, 48_000, 1, 2, 240)
    assert_raise ArgumentError, fn -> Resampler.process(converter, <<1>>) end
    assert_raise ArgumentError, fn -> Resampler.adjust(converter, 1_001) end
    assert {:ok, _pcm, _frames} = Resampler.process(converter, :binary.copy(<<0, 0>>, 240))
    assert :ok = Resampler.close(converter)
    assert {:error, :closed} = Resampler.process(converter, :binary.copy(<<0, 0>>, 240))
  end

  test "native error tuples become adapter failures, never successful controls" do
    assert {:error, %{code: :adapter_failed}} = LocalAudio.devices("nonexistent-host")
    pid = open()
    :ok = Device.close(:sys.get_state(pid).device)
    assert {:error, %{code: code}} = LocalAudio.control(pid, "clear-closed", {:clear_output, 1})
    assert code in [:adapter_failed, :closed]

    refute_receive {:parlora_event, %Event{type: :control_completed, command_id: "clear-closed"}},
                   30
  end

  def poll(_event, measurements, _metadata, {observer, pid}) do
    if self() == pid, do: send(observer, {:poll, measurements})
  end

  test "a delayed local poll correlates native underruns with current work, not historical peaks" do
    pid = open()
    handler = make_ref()
    :ok = :telemetry.attach(handler, [:parlora, :audio, :poll], &__MODULE__.poll/4, {self(), pid})
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok = :sys.suspend(pid)
    Process.sleep(150)
    :ok = :sys.resume(pid)

    assert_receive {:parlora_event,
                    %Event{
                      type: :audio_discontinuity,
                      payload: %{cause: :device_output_underrun, poll_gap_us: gap} = payload
                    }}
                   when gap >= 150_000,
                   1_000

    assert payload.frames > 0
    assert payload.output_rate > 0
    assert payload.last_capture_us >= 0
    assert payload.last_playback_us >= 0
    assert_receive {:poll, %{poll_gap_us: ^gap} = timing}, 1_000
    assert timing.capture_us >= timing.last_capture_us
    assert timing.playback_us >= timing.last_playback_us
    assert timing.observe_us >= timing.last_observe_us
  end
end
