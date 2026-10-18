# Playback hardening, October 3, 2026

The startup target stays **120 ms**. Browser and LocalAudio now receive bounded
bursts of at most 20 frames per transfer turn, and wake a blocked writer when its
next frame fits. This removes avoidable fragment timers and queue-space polling
delays without changing the media clock, queue capacity, recovery policy or DSP.
Adapters without notifications keep periodic polling, including the short
follow-up poll after draining a burst. Clear/suppression invalidate pending hints;
stale blockage timeouts cannot stop a recovered or newly cleared pipeline.

All three providers emit the same numeric receipt/read telemetry. Receipt counts
one decoded provider packet before fragmentation. Browser counters separately
count rendered source, inserted silence and partial-packet padding; the older
queue-read counter can lead rendered source by the staging buffer. No production
recorder, PCM retention or transcript logging was added.

## Complete-stream comparison

[comparison.json](comparison.json) retains all **640 results**: 320 current and
320 baseline cases. [summary.json](summary.json) is the compact comparison. The
baseline transfer loop is frozen from `de8ce59`; both loops use the same current
recovery policy and browser staging model. Nine 20-second synthetic schedules run
with three seeds and ten render phases. Five complete recorded windows run at all
ten phases. Comparisons within a schedule use identical PCM; the provider windows
are different generated utterances and do not rank providers against one another.

The replay models 1 ms transfer steps, 10 ms browser packetization and the separate
20 ms queue-read budget. It retains each source byte, including acoustic silence,
checks exact order, accounts for internal partial-packet padding, and drains beyond
the last receipt until the whole causal source timeline finishes. It measures
queue admission and local packetization, not network latency or human hearing.

The continuity floor is `max(0, max(arrival - preceding source duration) - start)`.
No finite startup cushion can beat this causal source deficit. The gate allows at
most the configured recovery cap plus one render tick (130 ms) above that floor,
and caps each recovery hold at 130 ms. All 320 current cases pass integrity,
bounded queues, completion, startup and applicable continuity checks. The ordinary
steady, jitter, variable, burst and 20 ms scheduler-stall cases insert no silence.

| Complete schedule, maximum across phases/seeds | Baseline | Current |
| --- | ---: | ---: |
| GPT capture: p99 arrival-to-channel admission | 9.907 ms | 0.995 ms |
| GPT capture: longest gap / gap count | 80 ms / 14 | 70 ms / 14 |
| GPT capture: total inserted silence | 410 ms | 410 ms |
| Older long capture: gap count | 1 | 1 |
| Steady: p99 admission / inserted silence | 9 ms / 0 | 0 / 0 |
| Burst: p99 admission / longest gap | 19 ms / 0 | 0 / 0 |
| Repeated sustained shortages: longest gap / total silence | 250 ms / 3,950 ms | 190 ms / 3,870 ms |
| Repeated sustained shortages: maximum gap count | 38 | 49 |

The last row is an adverse tradeoff, not a uniformly better listening result:
earlier transfer can fragment unavoidable gaps during persistent underproduction.
We retain the whole-stream measures rather than declaring success from the
largest gap alone. In the old short recording, one render phase also trades a
single longer gap for two gaps with equal total silence; the maximum across all
phases is two in both versions. The default recovery policy was not retuned.

## Provider captures

`capture.exs` records a bounded 45-second window of controlled generated output,
with silent input and no human microphone. It uses a serialized final read fence
before closing, verifies received bytes equal retained bytes with zero drops, and
writes failure evidence before raising. Audio stays outside the repository;
committed arrival fixtures contain numeric packet timing only. Replays substitute
a continuous chirp with the same byte lengths. Local receipt timing can include
client scheduling and transport delay; it does not identify the remote cause.
“Complete” means every receipt in the timed window is retained; it does not assert
that an utterance finished before the fence.

| Fixture | Packets | Source duration | Maximum cumulative receipt deficit | Dropped bytes |
| --- | ---: | ---: | ---: | ---: |
| GPT Live 1 | 438 | 43.800 s | 507.488 ms | 0 |
| Gemini standard Live | 30 | 9.560 s | 39.735 ms | 0 |
| Grok Think Fast 2.0 | 9 | 9.750 s | 0 | 0 |

The GPT window contains more delivery deficit than a 120 ms cushion can absorb.
The faster local refill improves admission but cannot remove that source shortage.
Gemini/Grok use their existing larger, bounded provider burst queues; channel
capacity remains 200 ms. Grok's capture initially overlapped virtual tests, so
these fixtures are replay inputs, not a quiescent provider latency benchmark.

## Regression and release checks

`test/recorded_audio_continuity_test.exs` runs the five recorded windows at all ten
phases in ordinary CI and verifies a five-second fast burst drains completely.
Focused tests cover burst fairness, readiness/space races, source and destination
identity, duplicate hints, epoch changes, suppression, recovery, deadlines, packet
padding and consistent provider telemetry. Telephony retains media-rate pipeline
pacing. Session/backend business logic and the native codecs are unchanged.

- Full macOS `mix ci`: 379 tests/properties passed, including six properties;
  native, Credo, clone, Unicode and Dialyzer checks passed.
- Standalone Sagents consumer: 199 tests passed; dev/prod compilation and packaged
  release smoke passed. Test support and Mix are absent from the release.
- Seeded stability: 100 session cycles and 500 retained corrections passed, with
  bounded memory/process growth and complete cleanup.
- Browser, CPU-load, concurrency and live checks are summarized in `verification.json`.

The seven ordinary decoded receiver cases and a 60-second jitter run with two CPU
workers passed, with zero interior silence and zero steady receiver concealment.
The live GPT Live 1 + Sagents browser-confirmation pilot passed, with zero reported
packet loss/concealment. The concurrency fixture passed one/two/four-call cohorts,
neighbor work during stall/disconnect, four-slot admission and resource cleanup.
It now explicitly pins Jido for its declared offline workload even when the
consumer includes Sagents dependencies.

The first actual WebRTC replay of the GPT arrival window is **a retained failure**
of the zero-concealment qualification gate: all 2,102,400 source bytes were
packetized, with 380 ms local silence, but Chromium reported 541 concealed samples
(about 11.3 ms) in one event despite zero packet loss. The server's largest tick
gap was 20.063 ms. The previous loop replay had 410 ms local silence and zero
concealment. One run per loop does not isolate the event's cause or establish a
regression. A separately retained current repeat passed with zero concealment,
400 ms local inserted silence and all source bytes packetized. Additional
attempts remain separately named in `verification.json`;
they cannot replace this failure or turn it into production certification.

An additional instrumented replay passed with all source bytes packetized, zero
packet loss/concealment and 390 ms of local silence during the known source
shortage. The playback clock's largest interval was 13.085 ms. A subsequent
120-second jitter soak with two CPU workers also passed, with zero interior
silence, zero packet loss/concealment and a largest playback interval of 12.515 ms.
Both traces were complete. These attempts did not reproduce the first event, so
its cause remains unresolved.

Validation can now retain bounded numeric timelines: server playback ticks and
input/output pipeline work, plus receiver statistics sampled every 100 ms. The
recorder is optional and session-filtered, retains at most 131,072 server rows and
4,096 receiver rows, and reports truncation. `analyze_timeline.py` summarizes
concealment poll windows, including events observed only in final statistics.
Separate clocks and coarse poll windows do not prove causal attribution. No
production recorder or startup/recovery policy change was added for this follow-up.

`analyze_recorded.py` keeps the ordinary no-gap report as `analysis.json` and writes
a separate shortage-aware gate. Its duration accounting uses locally inserted
silence, because Opus/NetEq can fill a quiet interval with nonzero decay or comfort
noise; an RMS silence threshold is not a source-timeline oracle. Exact byte/order
checks precede lossy Opus, while the actual receiver gate checks full packetization,
cleanup, bounded shortages, receiver concealment and decoded duration.

The CI alias now uses `test --raise`, so a failed suite stops subsequent Mix
checks. Earlier validation attempts remain failures: the legacy polling replay
exposed a real follow-up-poll regression, then passed after that fix; a new
telemetry test captured unrelated concurrent sessions until its handler was
filtered; Telnyx cleanup raced a linked shutdown; Twilio's immediate second pull
could outlive its 20 ms deadline under compilation load; the save-announcement
test could similarly outlive its idle deadline. The latter tests now use
supervision or explicit clock/state barriers instead of enlarging production
timeouts. The old refill test retains its one-gap assertion and exact output
oracle; the new burst loop changes its long-trial improvement from 70 to 50 ms.

An initial capture harness closed before its final arrivals were fenced. A second
Gemini capture did not acknowledge the provider's interruption barrier and failed
to retain all bytes. Those incomplete attempts are not used as passing captures.
The corrected harness acknowledges interruptions and fences the final read. An
initial replay also stopped one second after the last receipt and missed long
Gemini/Grok tails; both virtual and real receiver harnesses now use the complete
causal source timeline. Attempt metadata is retained in `verification.json`.
The first concurrency attempt omitted the installed optional dependency selection;
the next inherited Sagents for admission despite the fixture's Jido definition.
The corrected run selects installed dependencies and explicitly pins Jido in the
offline fixture. Neither failed attempt is presented as a passing concurrency run.

## Reproduce and limits

```sh
mix ci
mix test test/stability_test.exs --include stability --seed 42 --raise
MIX_ENV=test PARLORA_POLICY_REPORT=/tmp/playout-comparison.json \
  mix run validation/playout-hardening-20261003/compare.exs
scripts/audio_benchmark.sh /tmp/playout-audio
PARLORA_BACKEND=sagents scripts/consumer.sh /tmp/playout-consumer
PARLORA_BACKEND=sagents scripts/concurrency_check.sh /tmp/playout-consumer /tmp/playout-concurrency
```

Live capture uses the existing authorized Keychain launcher with
`PARLORA_PROVIDER`, `PARLORA_CAPTURE_OUTPUT` and `PARLORA_CAPTURE_SECONDS` (15–60).
Captures and standalone
apps belong in fresh output directories; validation must preserve failed attempts.

The receiver server accepts `AUDIO_REFERENCE_PCM` and `AUDIO_ARRIVAL_SCHEDULE` for
recorded timing, with PCM bounded to 60 seconds. For the GPT fixture, generate a
43,800 ms chirp using `Parlora.TestSupport.AudioBenchmark.Signal.pcm/1`, save it
outside the repository, and run with `AUDIO_SECONDS=45`. Use the ordinary
`validation/audio/receiver.cjs`, then `analyze_recorded.py OUTPUT gpt-live-arrivals.json`.
Set `AUDIO_BASELINE_PIPELINE=1` on the receiver server for the frozen baseline.
CPU soak uses `AUDIO_SECONDS=60` on both server/receiver and `AUDIO_CPU_WORKERS=2`
on the receiver. These options only belong to validation tooling.
The extended soak used `AUDIO_SECONDS=120`. CPU workers run for the requested
duration plus five seconds and are terminated when the receiver finishes.
To capture timing, set `AUDIO_TRACE_DIRECTORY` on the server and
`AUDIO_TIMELINE=1` on the receiver. Run
`python3 validation/playout-hardening-20261003/analyze_timeline.py OUTPUT SERVER_TRACE.json`
after cleanup; raw traces and PCM remain outside the repository.

These checks qualify bounded behavior on this macOS laptop and the tested
operating envelope. They do not certify arbitrary source stalls, VM overload,
WAN loss, OS devices or perceptual audio quality. Current Linux checks still need
CI execution; Docker's daemon was unavailable locally. A human listening call
with the final runtime remains necessary to judge the reported brief choppiness.
The existing harness keeps `production_ready: false`: two-minute load checks and
small concurrency pilots do not establish fleet capacity or long-call SLOs.
