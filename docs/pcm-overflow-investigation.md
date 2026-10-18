# PCM probe overflow: synthetic-device clock — 2026-09-20

## Finding

The reproduced failure is caused by **slow draining in the synthetic LocalAudio
harness**, rather than a large provider burst or inherently broken 24 kHz PCM.
Before the fix, `Device.open_test` rendered 480 frames at a declared 48,000 frames/second per
iteration, then slept for 10 ms. Callback work and sleep/scheduling delays added
to those 10 ms. There was no elapsed-time catch-up or absolute deadline in that
loop (`native/parlora_cpal/src/lib.rs`, synthetic branch of `start`). Real CPAL
streams use device callbacks, not this synthetic branch.

A device-only observation rendered **2,570 ms in 3,001.089 ms** of wall time:
**85.64% of the declared rate**, or an average 11.68 ms per nominal 10 ms block.
This check did not involve OpenAI, browser WebRTC, a backend job, or a physical
speaker. It establishes the harness clock discrepancy without relying on network
behavior. It does not identify how much individual delay comes from native work
versus OS sleep/scheduling.

The native queue consequently consumes audio slower than Parlora's real-time
producer. LocalAudio's bounded output queue fills, `write_audio` returns
backpressure, and AudioPipeline retains its pending frame instead of refilling
from OpenAI. The provider receive buffer then grows until its existing finite
capacity is exhausted. `AudioClock` compensates only up to 1,000 ppm (0.1%);
that is appropriate for small device drift, not this roughly 14–17% mismatch.

## New reproduction

The standalone consumer and repository `OutputBuffer`, `AudioTrace`,
`AudioPipeline`, `Pacer`, and `Limits` source hashes matched before measurement.
The live probe used the pinned toolchain, unchanged production limits, and
`device: :synthetic`. Numeric telemetry captured every receive/read transition
plus pipeline tick and forwarding measurements. No audio samples or credentials
were stored; the transcript in the log is generated demonstration text.

| Measurement | Result |
| --- | --- |
| Provider deliveries | 51 chunks, each 4,800 bytes / 100 ms |
| Time between first and last delivery | 5,004.890 ms |
| Delivery gaps | 90.025–106.743 ms; median 100.036 ms |
| Last second: forwarded audio | 830 ms |
| Last second: pipeline ticks | 99, including 16 blocked ticks |
| Last second: largest callback work | 1.279 ms |
| Last second: largest tick lateness | 4.792 ms |
| Receive queue before rejected chunk | 29,760 bytes / 620 ms |
| Incoming chunk | 4,800 bytes / 100 ms |
| Required capacity | 34,560 bytes / 720 ms |
| Configured capacity | 33,600 bytes / 700 ms |
| Oldest retained audio | 701.756 ms, below the 750 ms age limit |

Thus the receive capacity check, not the age check, rejects the next chunk.
`OpenAI.fail_audio` clears the retained queue, emits the discontinuity and failure,
and closes the provider. Pipeline callbacks are short; the repeated destination
backpressure explains the missing drain intervals. Adding buffer space would only
postpone failure while this rate mismatch continues.

## Controls and reproducible tests

1. The same bounded live save scenario with a **drain-only 24 kHz PCM channel**
   passed and finalized usage. There were 133 chunks, zero blocked ticks, zero
   dropped provider bytes, and a peak provider queue of 5,760 bytes / 120 ms.
   This retains the codec, provider, session pipeline and limits, removing the
   native playback harness. It is a separate live run, not identical network input.
2. `test/pcm_drain_regression_test.exs` replays the **exact captured arrivals and
   reads** against production `OutputBuffer` with synthetic identifiable bytes.
   It verifies every recorded read and queue transition and reproduces the exact
   29,760 + 4,800 > 33,600 failure.
3. The second test keeps those **same arrivals**, replaces only the slow reads
   with 20 ms reads at real-time cadence, and drains all 244,800 bytes in order
   without overflow or expiry under unchanged limits. This controls for different
   arrivals between live runs.

The tests are offline and require no key, network or physical device. They pass
by verifying the failure reproduction and healthy-drain control; passing them
alone does **not** verify the native clock correction described below.

## Evidence and commands

Evidence is in [validation/pcm-overflow](../validation/pcm-overflow/):
`evidence.json` retains all 352 provider transitions, the failure's bounded trace,
native clock counters and control summaries. `native.log`, `sink.log`, and
`device-clock.log` preserve the observed outcomes. Full tick traces were analyzed
locally; the retained fixture includes their numerical failure-window summary.

From the repository root:

```sh
mix test test/pcm_drain_regression_test.exs
mix run validation/pcm-overflow/device_clock.exs
```

From the standalone consumer, through the existing Keychain wrapper:

```sh
ORDER_DESK_DATABASE=:memory: PARLORA_SAVE_PROBE_FORMAT=pcm \
PARLORA_TRACE_OUTPUT=/tmp/parlora-pcm-trace.json \
python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/pcm-overflow/trace.exs
```

Use `PARLORA_SAVE_PROBE_FORMAT=pcm_sink` for the drain-only PCM control. The probe
is bounded to 40 seconds plus startup/cleanup and operates on an isolated
in-memory database. Set the documented native toolchain environment on macOS.

## Clock correction and retest

The synthetic device now schedules 480-frame blocks against elapsed monotonic
time, using absolute 10 ms deadlines. Callback work and sleep overshoot no longer
shift subsequent deadlines. Late wakeups catch up in batches of at most five
blocks, with a stop check before each block and a thread yield between overdue
batches. Backlog is represented by a deadline, not an expanding queue; existing
bounded sample queues retain their overflow/underrun accounting. Sleep is at most
10 ms. Real CPAL callbacks, provider limits and pipeline pacing are unchanged.

Three deterministic Rust tests cover repeated late wakeups plus callback work,
early wakeups, and a three-second stall recovered through bounded batches without
skipping frames. An ExUnit native-device test measures callbacks over 1.5 seconds
with a 50 ms tolerance, checks bounded capture while saturated, and verifies close.
Existing local audio tests also cover owner death, clear/resume and repeated close.

The independent macOS retest rendered **3,010 ms in 3,000.383 ms** (100.32%; the
observation includes callback-phase/polling differences). The live PCM24k synthetic
probe then completed the save announcement and finalized usage under unchanged
limits:

| Fixed-run measurement | Result |
| --- | --- |
| Received audio | 143 chunks / 686,400 bytes |
| Peak provider queue | 5,760 bytes / 120 ms |
| Blocked output ticks | 0 of 1,546 |
| Provider dropped bytes | 0 |
| Provider overflow / call failure | None |
| Local playback-starvation events | 3 |

Retained evidence: `device-clock-fixed.log`, `native-fixed.log`, and
`fixed-summary.json`. The original failure fixture remains intact. The live retest
uses fresh provider output, while the offline replay controls for identical
arrivals. The three starvation events are retained as a separate limitation:
this demonstrates recovery from the fatal clock-induced overflow, **not** glitch-free
physical playback. No physical speaker or browser was exercised by this probe.

The earlier PCM failures retained only failure codes, not their drain timing.
This new run reproduces the same fixture's failure and establishes its cause;
it cannot retroactively reconstruct those earlier arrival sequences. This is
also not evidence of a hardware CPAL or browser defect. Real devices and browser
paths retain their independent validation requirements, and the previously
observed provider burst limitation still exists for sufficiently large bursts.

## Verification

`mix ci` passes on macOS and Linux: 174 tests passed, 3 excluded, including the
native clock-rate test and both offline replay cases, plus five Rust CPAL tests
and all configured quality checks. The standalone consumer passes 107 tests on
macOS with the updated native source. Logs are retained with the evidence. Live
provider and synthetic-clock measurements were made on macOS; this investigation
does not claim a Linux live audio run.

## Playback-starvation follow-up

The remaining events were investigated separately with timestamped playout and
signal-level observations. A fresh run confirmed that the count includes both
silent boundaries and a potential audible gap caused by uneven arrival plus
rebuffering. See [the starvation investigation](playback-starvation-investigation.md)
for the measured 70/120/110 ms gaps, deterministic replay and limits of the evidence.
