defmodule Parlora.AcceptanceBurstTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, Limits}
  alias Parlora.Provider.OutputBuffer

  test "captured 600 ms burst drains in order at playback speed within the unchanged age limit" do
    evidence =
      File.read!("validation/acceptance/results/6-interrupt-disconnect.json") |> JSON.decode!()

    failure =
      Enum.find(evidence["events"], &(get_in(&1, ["payload", "cause"]) == "output_overflow"))

    events = failure["payload"]["audio_trace"]["events"]
    config = init(%Limits{})

    assert {:error, %{code: :output_overflow}} =
             replay(events, init(%Limits{provider_audio_queue_bytes: 24_000}))

    assert {:ok, queue, sequence, input, output} = replay(events, config)
    assert queue.bytes == 24_960
    assert byte_size(input) == 28_800
    assert byte_size(output) == 3_840

    # Continue the same 20 ms reads: the first is due just after the last arrival.
    last_read = events |> Enum.filter(&(&1["kind"] == "read")) |> List.last()

    {empty, output} =
      Enum.reduce(1..26, {queue, output}, fn tick, {queue, output} ->
        at = last_read["at_us"] + tick * 20_000
        {:ok, frames, queue} = OutputBuffer.read(queue, 960, config.limits, at)
        assert Enum.all?(frames, &(at - &1.timestamp_us < 750_000))
        {queue, output <> Enum.map_join(frames, & &1.data)}
      end)

    assert empty.bytes == 0
    assert output == input
    assert sequence == 60
    assert config.limits.audio_queue_bytes == 9_600
    assert config.limits.provider_audio_max_age_ms == 750
  end

  defp init(limits) do
    %AdapterInit{
      limits: limits,
      audio_format: %AudioFormat{},
      session_id: "acceptance-burst",
      adapter_id: "provider",
      generation: 0,
      event_sink: self()
    }
  end

  defp replay(events, config) do
    initial = {:ok, OutputBuffer.new(config.limits), 0, <<>>, <<>>}

    Enum.reduce_while(events, initial, &advance(&1, &2, config))
  end

  defp advance(%{"kind" => "received"} = event, {:ok, queue, seq, input, output}, config) do
    assert queue.bytes == event["queue_bytes"]
    pcm = :binary.copy(<<seq>>, event["bytes"])

    case OutputBuffer.push(queue, pcm, config, seq, event["at_us"]) do
      {:ok, {queue, seq}} -> {:cont, {:ok, queue, seq, input <> pcm, output}}
      error -> {:halt, error}
    end
  end

  defp advance(%{"kind" => "read"} = event, {:ok, queue, seq, input, output}, config) do
    {:ok, frames, queue} = OutputBuffer.read(queue, 960, config.limits, event["at_us"])
    pcm = Enum.map_join(frames, & &1.data)
    assert byte_size(pcm) == event["bytes"]
    assert queue.bytes == event["queue_bytes"]
    {:cont, {:ok, queue, seq, input, output <> pcm}}
  end
end
