alias Parlora.{AudioFormat, Limits}
alias Parlora.Providers.OpenAI
alias Parlora.TestSupport.AudioBenchmark.{Replay, Scenarios}

fixture =
  File.read!("validation/output-recovery-20261004/ended-call-envelope.json") |> Jason.decode!()

known =
  Enum.map_join(fixture["levels"], fn [bytes, peak] ->
    :binary.copy(<<min(peak, 32_767)::little-signed-16>>, div(bytes, 2))
  end)

pcm = known <> :binary.copy(<<32_767::little-signed-16>>, div(fixture["unknown_tail_bytes"], 2))
scenario = Scenarios.recorded(fixture["arrivals"], pcm)
{:ok, current} = Limits.new(OpenAI.audio_limits(%AudioFormat{}))

results =
  for phase <- 0..9,
      {name, limits} <- [{"previous_700ms", %Limits{}}, {"current_2000ms", current}] do
    result =
      Replay.run(scenario, phase * 1_000,
        limits: limits,
        playback_buffering: :adaptive,
        startup_limit_ms: 210
      )

    %{profile: name, result: result}
  end

File.write!(
  "validation/output-recovery-20261004/replay.json",
  Jason.encode!(results, pretty: true)
)

IO.inspect(
  Enum.map(results, fn row ->
    Map.merge(
      %{profile: row.profile},
      Map.take(row.result, [
        :phase_us,
        :failure,
        :played_bytes,
        :source_bytes,
        :peak_provider_bytes,
        :startup_us
      ])
    )
  end)
)
