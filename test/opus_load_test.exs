defmodule Parlora.OpusLoadTest do
  # Eight native streams deliberately saturate CPU. Run outside the async suite
  # so codec throughput does not become a lifecycle test's scheduling budget.
  use ExUnit.Case, async: false
  require Logger
  alias Parlora.Native.Opus, as: OpusProbe

  defp tone(index) do
    for i <- 0..479, into: <<>> do
      value = round(8_000 * :math.sin(2 * :math.pi() * 440 * (index * 480 + i) / 24_000))
      <<value::signed-little-16>>
    end
  end

  @tag timeout: 60_000
  test "eight independent streams encode and decode 160 seconds of audio" do
    started = System.monotonic_time(:microsecond)

    durations =
      1..8
      |> Task.async_stream(
        fn _ ->
          {:ok, encoder} = OpusProbe.new(:encoder, 24_000, 1, 2048)
          {:ok, decoder} = OpusProbe.new(:decoder, 24_000, 1, 2048)

          try do
            for i <- 0..999 do
              pcm = tone(i)

              {elapsed, _} =
                :timer.tc(fn ->
                  {:ok, packet} = OpusProbe.encode(encoder, pcm, 480)
                  {:ok, output, 480} = OpusProbe.decode(decoder, packet, 480, 0)
                  assert byte_size(output) == 960
                end)

              elapsed
            end
          after
            :ok = OpusProbe.close(encoder)
            :ok = OpusProbe.close(decoder)
          end
        end,
        max_concurrency: 8,
        timeout: 60_000
      )
      |> Enum.flat_map(fn {:ok, times} -> times end)
      |> Enum.sort()

    assert Enum.count(durations) == 8_000
    wall = (System.monotonic_time(:microsecond) - started) / 1_000_000

    Logger.info(
      "OPUS_LOAD wall_seconds=#{Float.round(wall, 3)} pairs=8000 " <>
        "p50_us=#{Enum.at(durations, 3999)} p95_us=#{Enum.at(durations, 7599)} p99_us=#{Enum.at(durations, 7919)}"
    )
  end
end
