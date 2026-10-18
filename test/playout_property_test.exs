defmodule Parlora.PlayoutPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Parlora.{AudioFrame, AudioQueue, Playout}
  alias Parlora.TestSupport.AudioBenchmark.Generators

  property "ordinary shortages never accumulate waiting when 100 ms is already queued" do
    check all(
            history <-
              list_of(tuple({integer(1..80_000), boolean()}), min_length: 2, max_length: 60),
            max_runs: Generators.runs()
          ) do
      initial = %{Playout.new(120, 9_600) | playing?: true}

      Enum.reduce(Stream.with_index(history), initial, fn {{shortage, quiet}, i}, state ->
        now = i * 500_000
        {_, empty, state} = Playout.take(state, %AudioQueue{}, 4_800, now)
        pcm = Generators.pcm(2_400, i * 2_400, quiet)
        {:ok, queue} = AudioQueue.push(empty, AudioFrame.pcm(pcm, "history", i))
        {output, queue, next} = Playout.take(state, queue, 4_800, now + shortage)
        assert output == pcm
        assert next.source_bytes - state.source_bytes == byte_size(pcm)
        assert queue.bytes == 0
        next
      end)
    end
  end

  property "a partial tail drains within the configured wait without another arrival" do
    check all(
            samples <- integer(1..239),
            shortage <- integer(1..600_000),
            buffer <- member_of([0, 10, 60, 120, 200]),
            quiet <- boolean(),
            max_runs: Generators.runs()
          ) do
      state = %{Playout.new(buffer, 9_600) | playing?: true}
      {_, empty, state} = Playout.take(state, %AudioQueue{}, 480, 0)
      pcm = Generators.pcm(samples, 0, quiet)
      {:ok, queue} = AudioQueue.push(empty, AudioFrame.pcm(pcm, "tail", 0))

      {output, queue, _state} =
        Enum.reduce(0..(div(buffer, 10) + 1), {<<>>, queue, state}, fn tick,
                                                                       {output, queue, state} ->
          {part, queue, next} = Playout.take(state, queue, 480, shortage + tick * 10_000)
          output = if next.source_bytes > state.source_bytes, do: output <> part, else: output
          {output, queue, next}
        end)

      assert output == pcm
      assert queue.bytes == 0
    end
  end
end
