defmodule BookingDesk.AmbienceTest do
  use ExUnit.Case, async: false
  alias BookingDesk.{Ambience, Recorder, ReplayChannel}

  test "continuous background wraps at the same phase and leaves caller gain unchanged" do
    noise =
      :binary.copy(<<100::signed-little-16>>, 240) <>
        :binary.copy(<<-200::signed-little-16>>, 240)

    state = %Ambience{pcm: noise, info: %{}}
    silent = :binary.copy(<<0>>, 480)
    {first, state} = Ambience.mix(state, silent)
    assert first == binary_part(noise, 0, 480)
    voice = :binary.copy(<<500::signed-little-16>>, 240)
    {second, state} = Ambience.mix(state, voice)
    assert second == :binary.copy(<<300::signed-little-16>>, 240)
    {again, state} = Ambience.mix(state, silent)
    assert again == first
    assert Ambience.info(state)["clipped_samples"] == 0
    assert Ambience.info(state)["mixed_ticks"] == 3
    assert Ambience.mix(nil, voice) == {voice, nil}
  end

  test "saturation is counted and never wraps a sample's sign" do
    state = %Ambience{
      pcm: <<1000::signed-little-16, -1000::signed-little-16>> <> :binary.copy(<<0>>, 476),
      info: %{}
    }

    {pcm, state} = Ambience.mix(state, <<32000::signed-little-16, -32000::signed-little-16>>)
    assert pcm == <<32767::signed-little-16, -32768::signed-little-16>>
    assert state.clipped_samples == 2
  end

  test "manifest mismatch is rejected before recording" do
    path =
      Path.join(System.tmp_dir!(), "booking-ambience-hash-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    File.write!(Path.join(path, "noise.pcm"), :binary.copy(<<1, 0>>, 240))

    File.write!(
      Path.join(path, "manifest.json"),
      JSON.encode!(%{
        pcm_file: "noise.pcm",
        pcm_sha256: "wrong",
        sample_rate: 24000,
        channels: 1,
        encoding: "pcm_s16le"
      })
    )

    assert_raise ArgumentError, fn ->
      Ambience.prepare!(Path.join(path, "manifest.json"), Path.join(path, "capture"))
    end
  end

  test "the actual replay sends the mixed samples to the input reader and records exact caller onset" do
    path =
      Path.join(
        System.tmp_dir!(),
        "booking-ambience-channel-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, recorder} = Recorder.start_link(directory: path)

    init = %Parlora.AdapterInit{
      session_id: "ambience-test",
      adapter_id: "a",
      generation: 0,
      event_sink: self(),
      audio_format: %Parlora.AudioFormat{},
      limits: %Parlora.Limits{}
    }

    noise = :binary.copy(<<100::signed-little-16>>, 240)

    {:ok, channel} =
      ReplayChannel.start_link(init,
        owner: self(),
        observer: Recorder.observer(recorder),
        ambience: %Ambience{pcm: noise, info: %{}}
      )

    assert_receive {:parlora_event, %{type: :ready}}
    assert_receive {:channel, ^channel}
    voice = :binary.copy(<<500::signed-little-16>>, 240)
    assert ReplayChannel.play(channel, voice, "search") == :ok
    # Read after a few real 10ms ticks so both idle ambience and the caller reach the input queue.
    Process.sleep(35)
    assert {:ok, frames} = ReplayChannel.read_audio(channel, 48000)
    values = for frame <- frames, <<sample::signed-little-16 <- frame.data>>, do: sample
    assert 600 in values
    assert 100 in values
    assert Enum.all?(values, &(&1 in [100, 600]))
    assert ReplayChannel.close(channel, "done", :normal) == :ok
    report = Recorder.finish(recorder, %{})

    assert [%{data: %{label: "search", bytes: 480, tick: tick}}] =
             Enum.filter(report.events, &(&1.name == "input:caller_started"))

    raw = File.read!(Path.join(path, "input.pcm"))
    assert binary_part(raw, tick * 480, 480) == :binary.copy(<<600::signed-little-16>>, 240)
    GenServer.stop(channel)
    GenServer.stop(recorder)
  end
end
