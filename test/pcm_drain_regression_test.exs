defmodule Parlora.PCMDrainRegressionTest do
  use ExUnit.Case, async: true
  alias Parlora.{AdapterInit, AudioFormat, Limits}
  alias Parlora.Provider.OutputBuffer

  setup do
    evidence = File.read!("validation/pcm-overflow/evidence.json") |> JSON.decode!()

    init = %AdapterInit{
      session_id: "drain-regression",
      adapter_id: "pcm",
      generation: 0,
      event_sink: self(),
      audio_format: %AudioFormat{},
      limits: %Limits{}
    }

    %{evidence: evidence, init: init}
  end

  test "recorded slow draining reproduces overflow despite evenly paced arrivals", %{
    evidence: evidence,
    init: init
  } do
    events = evidence["events"]
    arrivals = Enum.filter(events, &(&1["kind"] == "audio_received"))
    assert Enum.all?(arrivals, &(&1["bytes"] == 4_800))

    assert Enum.all?(Enum.chunk_every(arrivals, 2, 1, :discard), fn [first, next] ->
             (next["at_us"] - first["at_us"]) in 90_000..110_000
           end)

    {last, history} = List.pop_at(events, -1)
    {queue, sequence, _input, _output} = replay(history, init, true)
    assert queue.bytes == last["queue_before_bytes"]
    assert queue.bytes == 29_760
    assert queue.bytes + last["bytes"] == 34_560
    assert queue.capacity == 33_600
    assert evidence["failure"]["oldest_age_us"] < 750_000

    assert {:error, %{code: :output_overflow}} =
             OutputBuffer.push(
               queue,
               :binary.copy(<<0>>, last["bytes"]),
               init,
               sequence,
               last["at_us"]
             )
  end

  test "identical arrivals drain losslessly at real-time speed with unchanged limits", %{
    evidence: evidence,
    init: init
  } do
    arrivals = Enum.filter(evidence["events"], &(&1["kind"] == "audio_received"))
    start = hd(arrivals)["at_us"] + 10_000
    finish = List.last(arrivals)["at_us"] + 800_000
    reads = for at <- start..finish//20_000, do: %{"kind" => "audio_read", "at_us" => at}

    {queue, _sequence, input, output} =
      replay(Enum.sort_by(arrivals ++ reads, & &1["at_us"]), init, false)

    assert queue.bytes == 0
    assert output == input
    assert byte_size(input) == 51 * 4_800
  end

  defp replay(events, init, verify_measurements?) do
    Enum.reduce(events, {OutputBuffer.new(init.limits), 0, <<>>, <<>>}, fn event,
                                                                           {queue, seq, input,
                                                                            output} ->
      if event["kind"] == "audio_received" do
        verify(verify_measurements?, queue.bytes, event["queue_before_bytes"])
        pcm = :binary.copy(<<rem(seq, 256)>>, event["bytes"])
        assert {:ok, {queue, seq}} = OutputBuffer.push(queue, pcm, init, seq, event["at_us"])
        {queue, seq, input <> pcm, output}
      else
        assert {:ok, frames, queue} = OutputBuffer.read(queue, 960, init.limits, event["at_us"])
        pcm = Enum.map_join(frames, & &1.data)

        verify(verify_measurements?, byte_size(pcm), event["bytes"])
        verify(verify_measurements?, queue.bytes, event["queue_bytes"])

        {queue, seq, input, output <> pcm}
      end
    end)
  end

  defp verify(false, _actual, _expected), do: :ok
  defp verify(true, actual, expected), do: assert(actual == expected)
end
