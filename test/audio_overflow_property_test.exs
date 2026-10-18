defmodule Parlora.AudioOverflowPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parlora.{AdapterInit, AudioFormat, Error, Limits}
  alias Parlora.Provider.OutputBuffer
  alias Parlora.TestSupport.AudioBenchmark.Generators

  property "an oversized burst is rejected atomically and cannot corrupt queued samples" do
    check all(
            queued_samples <- integer(1..4_800),
            extra_samples <- integer(1..4_800),
            max_runs: Generators.runs()
          ) do
      init = %AdapterInit{
        limits: %Limits{},
        audio_format: %AudioFormat{},
        adapter_id: "overflow",
        session_id: "property",
        generation: 0,
        event_sink: self()
      }

      data = Generators.pcm(queued_samples, 0, false)

      {:ok, {queue, sequence}} =
        OutputBuffer.push(OutputBuffer.new(init.limits), data, init, 0, 0)

      too_large = :binary.copy(<<1, 0>>, div(queue.capacity - queue.bytes, 2) + extra_samples)

      assert {:error, %Error{code: :output_overflow}} =
               OutputBuffer.push(queue, too_large, init, sequence, 0)

      {:ok, frames, empty} = OutputBuffer.read(queue, queue.capacity, init.limits, 0)
      assert Enum.map_join(frames, & &1.data) == data
      assert empty.bytes == 0
    end
  end
end
