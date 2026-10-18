defmodule Parlora.AudioFormatTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, AudioFrame, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.Providers.OpenAI.Protocol

  test "μ-law uses one byte per sample, including odd chunks and encoded silence" do
    format = AudioFormat.pcmu()
    assert {:ok, limits} = Limits.new([], format)
    assert limits.audio_queue_bytes == 1_600
    assert limits.provider_audio_queue_bytes == 5_600
    assert limits.max_frame_bytes == 160
    assert AudioFormat.silence(format, 10) == :binary.copy(<<255>>, 80)

    frame = AudioFrame.new(<<0, 128, 255>>, format, "phone", 0)
    assert frame.duration_us == 375
    assert :ok = AudioFrame.validate(frame, format, limits)
    assert {:error, _error} = AudioFrame.validate(%{frame | duration_us: 62}, format, limits)
    assert {:error, _error} = AudioFrame.validate(frame, %AudioFormat{}, %Limits{})
    assert {:error, _error} = Limits.new([max_frame_bytes: 79], format)
    assert {:ok, _limits} = Limits.new([max_frame_bytes: 81], format)
    assert {:error, _error} = Limits.new([], %{format | sample_rate_hz: 24_000})
  end

  test "PCM defaults retain sample alignment, silence, and byte budgets" do
    assert {:ok, limits} = Limits.new()
    assert limits == %Limits{}
    assert AudioFormat.silence(%AudioFormat{}, 10) == :binary.copy(<<0>>, 480)
    frame = AudioFrame.pcm(<<0, 0, 1, 0>>, "device", 0)
    assert frame.duration_us == 83
    assert :ok = AudioFrame.validate(frame, %AudioFormat{}, limits)

    assert {:error, _error} =
             AudioFrame.validate(%{frame | data: <<0, 0, 1>>}, %AudioFormat{}, limits)
  end

  test "provider keeps the same duration bound and exact bytes for μ-law bursts" do
    format = AudioFormat.pcmu()
    {:ok, limits} = Limits.new([], format)

    init = %AdapterInit{
      limits: limits,
      audio_format: format,
      session_id: "phone-test",
      adapter_id: "provider",
      generation: 0,
      event_sink: self()
    }

    data = for n <- 0..5_598, into: <<>>, do: <<rem(n, 256)>>
    assert {:ok, {queue, 70}} = OutputBuffer.push(OutputBuffer.new(limits), data, init, 0, 0)
    assert {:error, %{code: :output_overflow}} = OutputBuffer.push(queue, <<0, 1>>, init, 70, 1)
    assert {:ok, frames, empty} = OutputBuffer.read(queue, 5_600, limits, 749_999)
    assert empty.bytes == 0
    assert Enum.map_join(frames, & &1.data) == data
    assert Enum.reduce(frames, 0, &(&1.duration_us + &2)) == 699_875
    assert Enum.all?(frames, &(AudioFrame.validate(&1, format, limits) == :ok))
    assert Enum.at(frames, 69).duration_us == 9_875

    assert {:error, %{code: :output_stale}} =
             OutputBuffer.read(queue, 160, limits, 750_000)
  end

  test "provider negotiates μ-law explicitly without accepting mismatched metadata" do
    format = AudioFormat.pcmu()
    assert {:ok, command} = Protocol.start([api_key: "test"], format)
    assert command.session.audio.format == %{type: "audio/pcmu", rate: 8_000}
    assert format in Protocol.capabilities().audio_formats

    assert {:error, %{code: :unsupported}} =
             Protocol.start([api_key: "test"], %{format | sample_format: :s16le})
  end
end
