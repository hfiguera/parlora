# Concurrent browser-session pilot

The 1-, 2-, and 4-call offline pilot passed on macOS arm64 and Linux x64 on
September 22, 2026 (September 23 UTC). Two simultaneous live-provider calls also
passed on macOS. This adds repeatable evidence for audio/result isolation, fault
containment, admission, and cleanup. It found no production-library defect.

[Compact measured results and evidence hashes](results.json) refer to library
revision `daa115e8345f56fb159471ecb6e3723de0c3fd76` plus the fixture hashes in that
file. Both hosts ran identical offline fixture sources. Raw audio, transcripts,
SQLite fixtures, and full traces stay in ignored `runs/` directories.

## What was exercised

The offline fixture uses real Chromium WebRTC, Opus, browser signaling, Parlora
sessions/audio pipelines, and Jido agents sharing the OrderDesk application Jido
instance. A local provider generates paced tones through the production provider
output buffer. Every session has distinct input/output frequencies and task
markers. Structured scripted captions drive tasks; the tones do not test ASR.

Each host ran a four-call warmup, normal cohorts of 1/2/4 calls, and two four-call
fault cohorts: 19 core sessions and 53 backend tasks. In each fault cohort, one
provider stalls or is killed; the three neighbors must finish work during its
cleanup, then finish another round and continue receiving audio. The stall uses
an explicitly armed 1.5-second assistant-caption deadline. A killed provider uses
the existing five-second session shutdown deadline.

A separate admission scenario negotiates real media through the unchanged
`OrderDesk.BrowserGate`: four calls become ready, the fifth is rejected, closing
one releases a slot, and a replacement becomes ready while the other three remain
connected. These five admitted sessions are additional to the 19 core sessions.
The four-call limit is an OrderDesk host policy, not a global limit in Parlora.

## Measurements

Submission-to-assistant-caption timing includes a fixed 200 ms backend action.
The p95 values below are descriptive order statistics of only 3/6/12 observations,
not estimated production latency percentiles.

| Host | Calls | p50 / p95 (ms) | BEAM CPU-equivalent cores |
| --- | ---: | ---: | ---: |
| macOS | 1 | 203.2 / 207.4 | 0.075 |
| macOS | 2 | 201.5 / 202.0 | 0.110 |
| macOS | 4 | 202.1 / 204.2 | 0.173 |
| Linux | 1 | 203.0 / 203.3 | 0.145 |
| Linux | 2 | 202.0 / 202.7 | 0.192 |
| Linux | 4 | 203.0 / 203.5 | 0.375 |

CPU is cumulative BEAM runtime divided by sampled cohort wall time. It excludes
Chromium and the Python scorer and is not host CPU utilization or a capacity limit.
Both hosts passed the same-run latency budget: concurrent p95 must stay below
`max(2 × single-call p95, single-call p95 + 250 ms)`.

| Observation | macOS | Linux |
| --- | ---: | ---: |
| Neighbor work during stall / killed-provider cleanup | 233 / 240 ms | 267 / 237 ms |
| Stalled / killed session cleanup | 1,511 / 5,023 ms | 1,545 / 5,074 ms |
| Peak sampled browser input / output queue | 1,440 / 6,720 bytes | 1,920 / 6,240 bytes |
| Peak sampled RTP queue | 3 packets | 3 packets |
| Peak provider source queue | 960 bytes | 960 bytes |
| Peak sampled BEAM memory, all cohorts | 159.25 MB | 196.92 MB |
| Post-warmup BEAM memory growth at final core cleanup | 3.75 MB | 0.04 MB |
| Active sessions / tracked surviving descendants after cleanup | 0 / 0 | 0 / 0 |

No foreign task markers or foreign tones were detected. All analyzed input and
output captures had zero internal silence gaps under the detector definition.
Queue assertions retain finite configured bounds plus staging: input 19,200 bytes,
output 10,560 bytes, RTP 32 packets, and provider source 33,600 bytes. The observer
samples VM/session processes every 200 ms and browser queues every 500 ms; it cannot
prove that no shorter peak occurred. Final post-warmup growth limits are 16 MB and
10 processes, alongside the stronger zero tracked session-resource survivor check.

## Live check

Two read-only synthetic Samantha recordings asked for orders 123 and 124, with
both calls sharing one BEAM, Jido instance, and TypeSafe client. Both reached the
correct backend target, accepted their own result, and produced the expected
response after their own result boundary. Input playback overlapped, and backend
execution overlapped by 1,001 ms. Saved orders were unchanged and active sessions
returned to zero. The batch ran once without retries, using `gpt-live-1` and
`jev-1.13.0` as recorded by the existing consumer configuration.

All four sampled interpreter requests succeeded (maximum 395 ms, sampled queue
peak 1). Both provider traces contained input and output captions with no omitted
events or truncated audio. This is a small functional live check; it does not
measure live speech intelligibility or use the offline tone continuity detector
on speech.

The live VM's final shutdown exposed a diagnostic-only race: telemetry could stop
before the interpretation collector detached its handler. The collector now
closes its file even when that dependency is already gone. An isolated regression
covers ordinary teardown and this shutdown order. The live evidence predates that
small fix and retains its original source hashes; the calls and cleanup had already
passed. No additional paid calls were needed to test a local teardown callback.

## Scorer qualification and limits

Identity checks use 20 ms windows across all audible captured audio. A foreign
candidate must exceed 10% of expected tone power and account for at least 5% of
total energy. Silence checks exclude one second at each signal edge, require at
least one second of interior observations, and allow no internal gap above 100 ms.
These bounds do not establish bit-perfect audio, speech intelligibility, packet
loss attribution, or absence of weaker/noncandidate contamination.

Eight scorer regressions cover clean audio, wrong routing, mixed routing, a
300 ms gap, foreign audio at startup, silence, a codec close tail, and a quiet
coherent foreign tone. `fixtures/codec-close-tail.pcm` is a synthetic 20 ms mono
48 kHz signed little-endian PCM fragment from the failed `macos-final` run, output
slot 2 at 11,900–11,920 ms. Its broad decay initially triggered a detector based
only on relative tone power; requiring tonal energy rejected that false positive
while the contamination negative controls still failed as intended. The original
failed report is retained, not reclassified as a pass.

Earlier qualification also corrected fixture syntax and an observation timeout
that equaled the library's five-second shutdown deadline. The observer now allows
7.5 seconds and requires neighboring work to finish while shutdown is pending.
These were harness corrections, not runtime fixes.

Four simultaneous calls is the tested scope, not a maximum safe production load.
This short loopback test does not establish human conversation coverage, tenant
authorization, long-session retention, TURN/WAN behavior, physical audio, telephony
concurrency, provider rate limits, or production throughput. It is a regression
check for the existing browser path under controlled load.

## Reproduce

Build a current consumer with `scripts/consumer.sh`, install the pinned browser
harness dependencies with `npm ci` in `validation/browser`, then install Chromium
with `npx playwright install --with-deps chromium` there. Python 3 is also required.
The consumer script supplies the pinned BEAM/Rust/native dependencies described
in the root development instructions.

```sh
scripts/concurrency_check.sh /absolute/consumer /absolute/new-output
```

This runs scorer regressions, the isolated diagnostic teardown regression, and
the offline browser pilot. Both OS CI jobs run it and upload compact JSON/log
artifacts. It does not load provider credentials. Each output directory must be
new. Reports include source hashes, platform/browser versions, per-cohort results,
queue/resource samples, and hashes of private captures. A source snapshot without
`.git` may set `CONCURRENCY_SOURCE_REVISION`; this labels the revision as explicit
and still verifies the installed consumer files against the snapshot.

The measured hosts used Elixir 1.20.4/OTP 29.0.6, Rust 1.92.0, Opus 1.6.1, and
Chromium 151.0.7922.34. Node was 26.8.2 on macOS and 22.16.0 on Linux. The fresh
Linux consumer also passed its 150 tests and production release smoke check.

After a passing offline report, the optional paid check runs exactly two synthetic
calls on macOS using the consumer's existing Keychain credential helper:

```sh
node validation/concurrency/live.cjs /absolute/consumer /absolute/new-live-output \
  /absolute/offline-output/report.json --live
```

Live evidence includes synthetic transcripts and provider input captures. Keep
those artifacts private. Only the compact results and evidence hashes are included
in version control.
