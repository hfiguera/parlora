# Bounded audio timing investigation — September 16, 2026

This records the earlier investigation. See [playback recovery](playback-recovery.md)
for the September 20 pacing and buffering changes and their measured tradeoffs.

## Conclusion

The ordinary controlled runs did **not** reproduce the fault. Both the macOS
physical-device path and Linux virtual-device path completed baseline and moderate
CPU-load runs with zero post-start native output underruns, zero native capture
drops, and zero software-inserted silence inside continuous source intervals.

A deliberate 150 ms suspension of the local channel reproduced simultaneous
capture overflow and output underrun. New timing evidence correctly identified
that known local stall. This validates the instrumentation and establishes a
possible mechanism; it does **not** establish the cause of the earlier live call.

Keep the measured 60 ms playback cushion and 30 ms native target unchanged.
The bounded investigation ends here. Retain the diagnostics for another naturally
occurring event and continue feature work; no speculative scheduling or buffering
change is justified by these measurements.

## Trigger and scope

The user first reported a brief audible gap near the end of a standalone voice
call. In two subsequent calls they heard no gap. One supplied 39-second call log
nevertheless recorded post-start output underruns at approximately 6.1 and 7.8
seconds, and capture overflow at 7.8 seconds. That log lacked per-poll timing and
native rates, so it cannot identify where processing was delayed or establish
whether speech was affected.

This follow-up used the separate `order_desk` consumer, its real session lifecycle,
Jido integration, CPAL/Rustler/Rubato channel, and application-defined offline
provider. The updated LocalAudio module was mirrored into its vendored dependency
for the experiment. No API calls or raw-audio recordings were required. The source
provider generated a quiet continuous 440 Hz tone; capture PCM was counted and
discarded. This isolates local timing from network/model delivery variability.

Each scenario ran for roughly 24 seconds after readiness: one second warmup,
ten seconds of tone, three seconds of source silence, and another ten seconds of
tone. The reported steady counters start at the first tone. Intentional source
pause transitions are excluded from the interior-silence measurement, with a
300 ms start margin and 100 ms end margin on each tone interval.

The CPU case used four workers on macOS (16 BEAM schedulers) and two on Linux
(8 schedulers), each alternating 20 ms of arithmetic work and 20 ms of sleep.
This is moderate contention, not full saturation, a measured CPU-utilization
percentage, or a test of every native scheduler workload. The control suspended
only the LocalAudio GenServer for 150 ms about five seconds after readiness;
native callbacks continued and the channel was resumed in a `try/after` block.

## Measurements

All device rates in these runs were 48 kHz. Underruns are missing output frames;
capture drops are lost input frames. Neither counter identifies speech content.

| Platform / scenario | Maximum poll gap | Output underrun frames after warmup | Capture dropped frames after warmup | Interior software silence |
| --- | ---: | ---: | ---: | ---: |
| macOS physical / baseline | 16.137 ms | 0 | 0 | 0 ms |
| macOS physical / CPU load | 8.024 ms | 0 | 0 | 0 ms |
| macOS physical / injected pause | 154.072 ms | 4,804 | 2,400 | 0 ms |
| Linux virtual / baseline | 8.274 ms | 0 | 0 | 0 ms |
| Linux virtual / CPU load | 7.028 ms | 0 | 0 | 0 ms |
| Linux virtual / injected pause | 151.978 ms | 4,864 | 2,400 | 0 ms |

During the macOS injected-pause observation, capture work took 269 µs and playback
work 390 µs; Linux measured 221 µs for each. The long interval between polls, rather
than expensive work in that resumed poll, explains the induced event. At 48 kHz,
the output counters represent about 100–101 ms of missing native output frames.
The zero software-silence result in that case is useful: a source queue can have
PCM while the native device runs empty because the channel isn't servicing it.

Baseline macOS capture/playback work had p99 values of 686/937 µs, with maxima of
10.106/10.726 ms. The moderate-load run did not worsen them. These are elapsed wall
times and include scheduling/preemption; they are not pure resampler CPU costs.
Native underruns during startup and source starvation at the intentional pause
are retained in the evidence separately from steady results.

[Machine-readable results](audio-timing-results.json) include per-scenario timing
percentiles, phase transitions, and discontinuity payloads. There is no raw PCM,
transcript, credential, or business result in that file.

## Instrumentation and regression coverage

Previously, `[:parlora, :audio, :poll]` exposed cumulative work maxima. It now also
reports:

- `poll_gap_us`: interval between starts of consecutive local polling cycles.
- `last_capture_us`, `last_playback_us`, `last_observe_us`: current cycle wall times.
- `input_rate`, `output_rate`, and queue depths in native frames.
- `session_id` and `adapter_id` metadata for correlating concurrent sessions.

Existing `capture_us`, `playback_us`, and `observe_us` remain cumulative maxima.
Telemetry now runs after timing the current observe operation. Native capture-drop
and output-underrun events include the poll gap, capture/playback work durations,
native rates and queue depths. Queue depths are sampled **after** capture/playback
service; they are not the depths at the instant the native discontinuity happened.
A polling gap alone does not distinguish BEAM scheduling, OS scheduling, mailbox
work, GC, or deliberate suspension.

The example and consumer display these additive fields in their existing audio
notices. `/mark` still lets a caller identify an audible symptom. A new synthetic
native regression test deliberately suspends the channel and verifies that the
underrun event and telemetry identify the same long polling interval, while current
work durations remain separate from historical maxima.

## Reproduce

After creating a consumer with `scripts/consumer.sh`, run from its directory:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
CPAL_INPUT='MacBook Pro Microphone' CPAL_OUTPUT='MacBook Pro Speakers' \
mix run -e 'OrderDesk.AudioProbe.run()'
```

The probe runs all three scenarios and prints one numeric JSON report. It bounds
stored telemetry at 40,000 samples and the discontinuity list at 200 per scenario.
It cleans up its workers, sessions, telemetry handlers and ETS tables between
scenarios. Run it in an otherwise idle consumer with no other sessions.

On Linux, use the native pinned toolchain, set `CPAL_HOST=PulseAudio`, and select
a temporary virtual sink/monitor through `CPAL_OUTPUT`/`CPAL_INPUT`. Physical
Linux hardware remains unverified. Tests do not cover Bluetooth, device switching,
OS sleep/wake, sustained CPU saturation, arbitrary network jitter, or subjective
speech quality. A forced pause is a diagnostic control, not proof of a production
bug or proof that the original audible issue is fixed.

## Verification

`mix ci` passed on macOS and Linux: 77 regular ExUnit tests, native checks,
strict Credo/ExSlop, zero ExDNA clones, Credence, and Dialyzer. The three separately
tagged stability tests were excluded by the standard command. The updated
consumer compiled and its two integration tests passed on both platforms;
consumer formatting also passed on macOS. The six timing scenarios above are
separate physical/virtual measurements, not part of ordinary CI.
