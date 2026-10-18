Code.require_file(Path.join(__DIR__, "../recovery-wait-20261004/reference.exs"))
alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios}

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
      signal <- [:nonquiet, :quiet_passages],
      policy <- [RecoveryWaitReference, Parlora.Playout] do
    pcm =
      if signal == :quiet_passages,
        do: quiet_pcm,
        else: :binary.copy(<<4_000::little-signed-16>>, 480_000)

    result =
      Replay.run(Scenarios.build(name, 42, 20_000, pcm), phase,
        policy: policy,
        playback_buffering: :adaptive,
        startup_limit_ms: 210
      )

    %{scenario: name, phase: phase, signal: signal, policy: inspect(policy), result: result}
  end

# Continuous nonquiet PCM cannot qualify for the new gate. Its behavior must
# match the frozen policy, not merely satisfy the broad safety limits.
for [reference, candidate] <- Enum.chunk_every(rows, 2), reference.signal == :nonquiet do
  fields = [:gaps, :startup_us, :inserted_silence_us, :max_playout_age_us, :played_bytes]

  unless Map.take(reference.result, fields) == Map.take(candidate.result, fields),
    do: raise("continuous nonquiet control changed")
end

File.write!(Path.join(__DIR__, "controls.json"), Jason.encode!(rows))

IO.inspect(%{cases: length(rows), failures: Enum.filter(rows, &(not &1.result.passed))},
  limit: :infinity
)

unless Enum.all?(rows, & &1.result.passed), do: raise("control failed")
