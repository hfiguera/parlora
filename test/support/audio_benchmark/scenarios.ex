defmodule Parlora.TestSupport.AudioBenchmark.Scenarios do
  @moduledoc false
  alias Parlora.TestSupport.AudioBenchmark.Signal

  def timeline(scenario) do
    {bytes, deficit} =
      Enum.reduce(scenario.events, {0, 0}, fn {at, pcm}, {bytes, deficit} ->
        elapsed = div(bytes * 1_000_000, 48_000)
        {bytes + byte_size(pcm), max(deficit, at - elapsed)}
      end)

    duration = div(bytes * 1_000_000, 48_000)
    %{duration_us: duration, deficit_us: deficit, causal_finish_us: duration + deficit}
  end

  def recorded(arrivals, pcm) do
    first = hd(arrivals)["at_us"]

    {events, <<>>} =
      Enum.map_reduce(arrivals, pcm, fn arrival, remaining ->
        bytes = arrival["bytes"]
        <<part::binary-size(^bytes), rest::binary>> = remaining
        {{arrival["at_us"] - first, part}, rest}
      end)

    %{name: :recorded, seed: 0, pcm: pcm, events: events, normal?: false, stall: nil}
  end

  def build(name, seed, duration_ms \\ 3_000, pcm \\ nil) do
    random = :rand.seed_s(:exsss, {seed + 1, seed + 17, seed + 103})
    pcm = pcm || reference(name, duration_ms)
    {events, _random} = chunks(pcm, name, 0, 0, random, [])

    %{
      name: name,
      seed: seed,
      pcm: pcm,
      events: events,
      normal?: name in [:steady, :jitter, :burst, :variable, :scheduler],
      stall: if(name == :scheduler, do: {1_000_000, 1_020_000}, else: nil)
    }
  end

  defp reference(:repeated_shortages, duration_ms) do
    Signal.pcm(duration_ms)
    |> :binary.bin_to_list()
    |> Enum.chunk_every(4_800)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, i} ->
      if rem(i, 20) < 5, do: :binary.copy(<<0>>, length(chunk)), else: :binary.list_to_bin(chunk)
    end)
    |> IO.iodata_to_binary()
  end

  defp reference(_name, duration_ms), do: Signal.pcm(duration_ms)

  defp chunks(<<>>, _name, _offset, _previous, random, events),
    do: {Enum.reverse(events), random}

  defp chunks(pcm, name, offset, previous, random, events) do
    {r, random} = :rand.uniform_s(100, random)
    ms = chunk_ms(name, r)
    bytes = min(ms * 48, byte_size(pcm))
    <<part::binary-size(^bytes), rest::binary>> = pcm
    at = max(previous, arrival(name, offset, r))
    chunks(rest, name, offset + div(bytes, 48), at, random, [{at * 1_000, part} | events])
  end

  defp chunk_ms(:variable, random), do: Enum.at([10, 20, 50, 100], rem(random, 4))
  defp chunk_ms(:burst, _random), do: 200
  defp chunk_ms(_name, _random), do: 100

  defp arrival(:jitter, offset, random), do: offset + rem(random, 61)
  defp arrival(:variable, offset, random), do: offset + rem(random, 21)
  defp arrival(:shortage, offset, _random) when offset >= 1_000, do: offset + 250
  defp arrival(:underproduction, offset, _random), do: div(offset * 14, 10)
  defp arrival(:late_bursts, offset, _random), do: offset + div(offset, 1_000) * 30

  defp arrival(:repeated_shortages, offset, _random) do
    cycle = div(offset, 2_000)
    position = rem(offset, 2_000)

    extra =
      [{300, 70}, {600, 60}, {900, 90}, {1_200, 147}, {1_500, 30}]
      |> Enum.filter(fn {at, _delay} -> position >= at end)
      |> Enum.reduce(0, fn {_at, delay}, total -> total + delay end)

    offset + cycle * 397 + extra
  end

  defp arrival(:overflow, _offset, _random), do: 0
  defp arrival(_name, offset, _random), do: offset
end
