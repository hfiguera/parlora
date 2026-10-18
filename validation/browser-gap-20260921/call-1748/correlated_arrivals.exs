alias Parlora.TestSupport.AudioBenchmark.{Replay, Signal}
for extra <- [0, 30] do
  pcm = Signal.pcm(20_000)
  events = for {part, i} <- Enum.with_index(for <<part::binary-size(4800) <- pcm>>, do: part), do: {(i * 100 + div(i, 10) * extra) * 1_000, part}
  scenario = %{name: :correlated_arrivals, seed: 0, pcm: pcm, events: events, normal?: true, stall: nil}
  results = for phase <- 0..9, do: Replay.run(scenario, phase * 1_000)
  IO.puts(Jason.encode!(%{extra_ms_every_ten_chunks: extra, results: results}))
end
