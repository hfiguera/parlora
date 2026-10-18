Code.require_file(Path.join(__DIR__, "../recovery-wait-20261004/reference.exs"))
gaps = File.read!("test/support/audio_benchmark/gaps.ex")

gaps =
  gaps
  |> String.replace(
    "defmodule Parlora.TestSupport.AudioBenchmark.Gaps do",
    "defmodule QuietGaps do"
  )
  |> String.replace("now)\n      when current", "_position, now)\n      when current")
  |> String.replace("_gap, now)", "_gap, position, now)")
  |> String.replace("true, now)", "true, position, now)")
  |> String.replace("_gap, _now)", "_gap, _position, _now)")
  |> String.replace(
    "%{start: now, returned: nil}",
    "%{start: now, returned: nil, position: position}"
  )
  |> String.replace(
    "duration_us: now - current.start,",
    "duration_us: now - current.start, source_position_bytes: current.position,"
  )

Code.compile_string(gaps)

replay =
  File.read!("test/support/audio_benchmark/replay.ex")
  |> String.replace(
    "defmodule Parlora.TestSupport.AudioBenchmark.Replay do",
    "defmodule QuietReplay do"
  )
  |> String.replace(
    "alias Parlora.TestSupport.AudioBenchmark.{Gaps, Packet, Scenarios, Source}",
    "alias Parlora.TestSupport.AudioBenchmark.{Packet, Scenarios, Source}\n  alias QuietGaps, as: Gaps"
  )
  |> String.replace(
    "Gaps.observe(state.gaps, source?, target.outbound.bytes > 0, gap?, now)",
    "Gaps.observe(state.gaps, source?, target.outbound.bytes > 0, gap?, state.rendered_source_bytes, now)"
  )

Code.compile_string(replay)
alias Parlora.TestSupport.AudioBenchmark.Scenarios

results =
  for name <- ["first-level-call", "heard-middle-call"] do
    fixture = File.read!(Path.join(__DIR__, name <> ".json")) |> Jason.decode!()

    pcm =
      Enum.map_join(fixture["levels"], fn [bytes, peak] ->
        :binary.copy(<<min(32767, peak)::little-signed-16>>, div(bytes, 2))
      end)

    pcm = pcm <> :binary.copy(<<32767::little-signed-16>>, div(fixture["unknown_tail_bytes"], 2))
    scenario = Scenarios.recorded(fixture["arrivals"], pcm)

    rows =
      for phase <- 0..9000//1000, policy <- [RecoveryWaitReference, Parlora.Playout] do
        result =
          QuietReplay.run(scenario, phase,
            policy: policy,
            playback_buffering: :adaptive,
            startup_limit_ms: 210
          )

        gaps =
          Enum.map(result.gaps, fn g ->
            pos = g.source_position_bytes

            peak = fn data ->
              for(<<n::little-signed-16 <- data>>, do: abs(n)) |> Enum.max(fn -> 0 end)
            end

            before = binary_part(pcm, max(0, pos - 480), min(pos, 480))
            following = binary_part(pcm, pos, min(480, byte_size(pcm) - pos))

            Map.merge(g, %{
              peak_before: peak.(before),
              peak_after: peak.(following),
              known_levels: pos + 480 <= fixture["known_level_bytes"]
            })
          end)

        %{phase: phase, policy: inspect(policy), result: %{result | gaps: gaps}}
      end

    %{capture: name, rows: rows}
  end

File.write!(Path.join(__DIR__, "comparison.json"), Jason.encode!(results))

summary =
  Enum.map(results, fn capture ->
    pairs =
      Enum.chunk_every(capture.rows, 2)
      |> Enum.map(fn [old, new] ->
        metrics = fn row ->
          nonquiet =
            Enum.filter(
              row.result.gaps,
              &(&1.known_levels and &1.peak_before > 100 and &1.peak_after > 100)
            )

          %{
            passed: row.result.passed,
            nonquiet_count: length(nonquiet),
            nonquiet_us: Enum.sum(Enum.map(nonquiet, & &1.duration_us)),
            max_nonquiet_us: Enum.max(Enum.map(nonquiet, & &1.duration_us), fn -> 0 end),
            inserted_silence_us: row.result.inserted_silence_us,
            max_playout_age_us: row.result.max_playout_age_us,
            startup_us: row.result.startup_us
          }
        end

        baseline = metrics.(old)
        candidate = metrics.(new)

        passed =
          baseline.passed and candidate.passed and
            candidate.nonquiet_count <= baseline.nonquiet_count and
            candidate.nonquiet_us <= baseline.nonquiet_us and
            candidate.max_nonquiet_us <= baseline.max_nonquiet_us and
            candidate.inserted_silence_us - baseline.inserted_silence_us <= 200_000 and
            candidate.max_playout_age_us <= 400_000 and
            candidate.startup_us == baseline.startup_us

        %{phase: old.phase, baseline: baseline, candidate: candidate, passed: passed}
      end)

    %{capture: capture.capture, pairs: pairs}
  end)

File.write!(Path.join(__DIR__, "summary.json"), Jason.encode!(summary, pretty: true))
IO.inspect(summary, limit: :infinity)

unless Enum.all?(summary, fn capture -> Enum.all?(capture.pairs, & &1.passed) end),
  do: raise("paired replay regression")
