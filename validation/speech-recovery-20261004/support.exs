Code.require_file(Path.join(__DIR__, "reference.exs"))
gaps = File.read!("test/support/audio_benchmark/gaps.ex")

gaps =
  gaps
  |> String.replace(
    "defmodule Parlora.TestSupport.AudioBenchmark.Gaps do",
    "defmodule SpeechRecoveryGaps do"
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
    "defmodule SpeechRecoveryReplay do"
  )
  |> String.replace(
    "alias Parlora.TestSupport.AudioBenchmark.{Gaps, Packet, Scenarios, Source}",
    "alias Parlora.TestSupport.AudioBenchmark.{Packet, Scenarios, Source}\n  alias SpeechRecoveryGaps, as: Gaps"
  )
  |> String.replace(
    "Gaps.observe(state.gaps, source?, target.outbound.bytes > 0, gap?, now)",
    "Gaps.observe(state.gaps, source?, target.outbound.bytes > 0, gap?, state.rendered_source_bytes, now)"
  )

Code.compile_string(replay)
