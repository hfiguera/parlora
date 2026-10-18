defmodule Parlora.TestSupport.AudioBenchmark.Generators do
  @moduledoc false
  import StreamData

  def packets(envelope) do
    sizes =
      if envelope == :normal, do: [10, 20, 30, 50, 70, 100], else: [10, 20, 30, 50, 70, 100, 200]

    list_of(
      tuple({member_of(sizes), integer(0..300), boolean()}),
      min_length: 1,
      max_length: 35
    )
  end

  def commands do
    list_of(
      frequency([
        {5, tuple({constant(:write), integer(1..480)})},
        {5, tuple({constant(:tick), integer(1..10)})},
        {2, constant(:clear)},
        {2, constant(:stop)},
        {2, constant(:resume)},
        {2, constant(:stale)}
      ]),
      min_length: 1,
      max_length: 70
    )
  end

  def scenario(packets, tail_samples, envelope) do
    {events, {offset, previous, sample}} =
      Enum.map_reduce(packets, {0, 0, 0}, fn {ms, delay, quiet}, {offset, previous, sample} ->
        delay = if envelope == :normal, do: rem(delay, 21), else: delay
        at = max(previous, offset + delay * 1_000)
        data = pcm(ms * 24, sample, quiet)
        {{at, data}, {offset + ms * 1_000, at, sample + ms * 24}}
      end)

    events = events ++ [{max(offset, previous), pcm(tail_samples, sample, false)}]

    %{
      name: :property,
      seed: 0,
      events: events,
      pcm: Enum.map_join(events, &elem(&1, 1)),
      normal?: envelope == :normal,
      stall: nil
    }
  end

  def pcm(samples, _offset, true), do: :binary.copy(<<0, 0>>, samples)

  def pcm(samples, offset, false) do
    for i <- offset..(offset + samples - 1),
        into: <<>>,
        do: <<rem(i * 197, 60_000) - 30_000::little-signed-16>>
  end

  def runs do
    case Integer.parse(System.get_env("PARLORA_PROPERTY_RUNS", "50")) do
      {n, ""} when n in 1..10_000 -> n
      _invalid -> raise "PARLORA_PROPERTY_RUNS must be 1..10000"
    end
  end
end
