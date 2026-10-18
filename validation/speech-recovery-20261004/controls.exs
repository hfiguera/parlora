Code.require_file(Path.join(__DIR__, "support.exs"))
alias Parlora.TestSupport.AudioBenchmark.Scenarios
alias SpeechRecoveryReplay, as: Replay

quiet_pcm =
  Enum.map_join(0..199, fn index ->
    sample = if rem(index, 7) in [4, 5], do: 32, else: 4_000
    :binary.copy(<<sample::little-signed-16>>, 2_400)
  end)

rows =
  for name <- [
        :steady,
        :jitter,
        :burst,
        :variable,
        :scheduler,
        :shortage,
        :underproduction,
        :late_bursts,
        :repeated_shortages
      ],
      phase <- [0, 3_000, 7_000],
      seed <- [7, 42, 91],
      signal <- [:nonquiet, :quiet_passages],
      policy <- [SpeechRecoveryReference, Parlora.Playout] do
    pcm =
      if signal == :quiet_passages,
        do: quiet_pcm,
        else: :binary.copy(<<4_000::little-signed-16>>, 480_000)

    result =
      Replay.run(Scenarios.build(name, seed, 20_000, pcm), phase,
        policy: policy,
        playback_buffering: :adaptive,
        startup_limit_ms: 210
      )

    nonquiet =
      Enum.filter(result.gaps, fn gap ->
        pos = gap.source_position_bytes

        peak = fn at ->
          for(
            <<n::little-signed-16 <-
                binary_part(pcm, max(0, at), min(480, byte_size(pcm) - max(0, at)))>>,
            do: abs(n)
          )
          |> Enum.max(fn -> 0 end)
        end

        peak.(pos - 480) > 64 and peak.(pos) > 64
      end)

    %{
      scenario: name,
      seed: seed,
      phase: phase,
      signal: signal,
      policy: inspect(policy),
      result: result,
      nonquiet_gaps: nonquiet
    }
  end

File.write!(Path.join(__DIR__, "controls.json"), Jason.encode!(rows))

for [reference, candidate] <- Enum.chunk_every(rows, 2) do
  duration = fn gaps -> Enum.sum(Enum.map(gaps, & &1.duration_us)) end
  maximum = fn gaps -> Enum.max(Enum.map(gaps, & &1.duration_us), fn -> 0 end) end

  unless length(candidate.nonquiet_gaps) <= length(reference.nonquiet_gaps) and
           duration.(candidate.nonquiet_gaps) <= duration.(reference.nonquiet_gaps) and
           maximum.(candidate.nonquiet_gaps) <= maximum.(reference.nonquiet_gaps) and
           candidate.result.inserted_silence_us <= reference.result.inserted_silence_us + 200_000 and
           candidate.result.max_playout_age_us <= 400_000 and
           candidate.result.startup_us == reference.result.startup_us and
           candidate.result.played_bytes == reference.result.played_bytes,
         do:
           raise(
             "paired control regressed: #{inspect({reference.scenario, reference.phase, reference.signal, reference.nonquiet_gaps, candidate.nonquiet_gaps})}"
           )
end

compact =
  Enum.map(rows, fn row ->
    result = row.result

    Map.take(row, [:scenario, :seed, :phase, :signal, :policy])
    |> Map.merge(
      Map.take(result, [
        :passed,
        :checks,
        :inserted_silence_us,
        :max_playout_age_us,
        :startup_us,
        :played_bytes
      ])
    )
    |> Map.merge(%{
      nonquiet_count: length(row.nonquiet_gaps),
      nonquiet_us: Enum.sum(Enum.map(row.nonquiet_gaps, & &1.duration_us)),
      max_nonquiet_us: Enum.max(Enum.map(row.nonquiet_gaps, & &1.duration_us), fn -> 0 end)
    })
  end)

File.write!(Path.join(__DIR__, "controls-summary.json"), Jason.encode!(compact))

IO.inspect(%{cases: length(rows), failures: Enum.filter(rows, &(not &1.result.passed))},
  limit: :infinity
)

unless Enum.all?(rows, & &1.result.passed), do: raise("control failed")
