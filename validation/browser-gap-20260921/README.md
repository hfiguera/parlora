# Browser gap investigation — September 21, 13:09 call

## Finding and its limit

The current recovery policy can approximately **double a source shortage between
120 and 200 ms**. It measures how long the queue was empty, then waits that long
again after source audio returns. The preceding fix reduced the wait for short
shortages to 120 ms; it did not eliminate this medium-shortage tradeoff.

This is a confirmed mechanism in production `Parlora.Playout`, reproduced through
Browser.Media and Opus. It is **not a complete attribution of the original live
gap**. The retained call has no source-return timestamp or recovery-release reason.
The exact duration split, and why the source queue initially emptied, cannot be
recovered from its summaries alone.

## What the call actually records

`call-evidence.json` preserves the browser's visible captions and diagnostic text
for the 13:09:19–13:10:49 manual call after commit `fd1927b`.

At 13:10:37, gap 10 has:

- 16,800 inserted zero bytes: 35 ten-millisecond PCM output blocks / **350 ms**.
- **349,110 microseconds** between the first empty observation and source resumption.
- PCM16 boundary peaks **4,960 / 5,344**, measured before Opus encoding.
- Epoch 0, ending with `source_resumed`, not a clear or close.

This is actual software-inserted PCM silence, not merely a warning counter or an
unmeasured browser packet-loss report. Wall time and generated duration are close;
a single 350 ms scheduler freeze would not explain the 35 output blocks. This
does not exclude smaller timing variations or upstream process delays. The peaks
do not identify phonemes or prove an audible clipped syllable.

No overflow/failure event is retained. All four backend jobs had completed and
been accepted by 13:10:16, before the interval. The server log contains startup
messages rather than per-frame history, and `/health` reported zero active
sessions after disconnect. Neither this evidence nor the captions establish the
precise spoken phrase at the gap.

## Mechanism

`lib/parlora/playout.ex` records `empty_since_us` at queue exhaustion and
`waiting_since_us` at the first nonempty playout read. It then computes:

```
shortage = first_available_read - first_empty_read
hold = min(200 ms, max(120 ms, shortage)) # default queue and buffer settings
resume once time_since_first_available_read >= hold
```

Upstream pressure can release the hold early. Otherwise, at the defaults:

- 30 ms shortage + 120 ms hold = 150 ms gap.
- 70 ms shortage + 120 ms hold = 190 ms gap.
- **170 ms shortage + 170 ms hold = 340 ms gap.**

Playback checks this deadline on a ten-millisecond output tick. A tick just before
the deadline waits until the following tick. The replay's small, explicitly
constructed timing variation produces **349.11 ms elapsed / 350 ms inserted**
from a 170 ms shortage. It uses 120 ms of returned source PCM; the remaining
179.11 ms is measured waiting with playable samples in the channel queue.
This exact numerical match is a control, not evidence that the live arrivals
followed that schedule.

The policy deliberately preserves a refill period after a shortage to avoid
repeated gaps; previous recorded-arrival tests show that releasing merely because
the channel fills can bring those gaps back. Matching the preceding shortage is
an estimate, not a measurement of how much additional buffering the next speech
segment needs. No new correction is implemented in this investigation.

## Reproduction and counterexample

Run from the repository root with the pinned toolchain:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
mix run validation/browser-gap-20260921/replay.exs
```

`replay-results.json` retains six asserted production Media/Playout/Opus controls
and their queue/tick histories. All six assertions passed on macOS and Linux.
The zero-hold control returns the same synthetic
source after 170 ms and resumes immediately: it isolates the policy's added wait.
It is a test control, not a proposed removal of recovery.

A separate control returns source later and injects the existing recovery-release
hint. It yields **the identical gap summary** with **zero additional recovery
wait**. The hint is test-injected; no provider pressure is measured or asserted in
that control. This counterexample demonstrates why the original summary cannot
tell us how much was absence versus intentional buffering. It does not assert
that this alternative happened in the call.

## Missing evidence and next correction

`PlaybackDiagnostics` retains duration, inserted silence and boundary peaks, but
not first-source-return time, queue occupancy on return/resumption, the calculated
hold deadline, or whether pressure released it. OpenAI's bounded receive/read trace
is emitted on provider audio failure; normal session close does not export it.
This call had no such failure. There is no retained, aligned provider arrival and
pipeline-transfer trace to connect to gap 10.

The next correction should first split a gap into measured source-unavailable
and recovery-wait intervals, record the release reason, and correlate bounded
provider-arrival / pipeline-transfer timing. Then tune the additional recovery
wait using those observations while preserving the existing short-tail,
recorded-jitter, overflow, queue-bound and clear/epoch regressions. Simply lowering
or removing all recovery is not validated by this investigation.

No live call, credentials, application data, or server configuration was changed.

## Implemented correction

The investigation above describes `fd1927b`. The subsequent correction makes the
refill hold equal to the configured initial cushion: **120 ms by default**, capped
by min(200 ms, queue duration). It no longer scales with the preceding shortage.
A full queue alone still does not end the wait; pressure release, zero buffering,
short tails, sample order, finite queue bounds and clear/epoch behavior remain.

Browser gap observations now retain first-source-available read time, return/resume
queue occupancy, target hold, unavailable-source time, actual recovery waiting,
and release reason. They reach both the browser's retained event log and status
summaries. Clear/close preserve partial observations without claiming resumption.
These measure channel read availability, not the provider's network-arrival time.

`replay.exs` now labels its old adaptive runs as explicit historical controls,
setting that hold in the fixture. It preserves `replay-results.json` and writes
`replay-fix-results.json`. The new current-policy control measures:

| Control | Source unavailable | Recovery waiting | Inserted PCM silence |
| --- | --- | --- | --- |
| Historical adaptive, small tick variation | 170 ms | 179.11 ms | 350 ms |
| Current fixed refill | 170 ms | 120 ms | 290 ms |

The two formerly identical gap summaries now differ in their measured components
and release reason. The test-injected pressure case reports zero recovery wait
and `pressure`; the historical wait reports `deadline`.

Recorded provider-arrival tests still leave only the original single gaps at
source positions 1,200 and 10,100 ms. The longer fixture inserts **310 ms** total
versus 380 ms under the intermediate adaptive policy and 320 ms with the earlier
queue-triggered policy that created a second interruption. The historical burst
baseline explicitly sets a 200 ms hold; all ten phases still reproduce overflow,
while production pressure-aware recovery preserves all 52,800 source bytes without
overflow. No checks for sample preservation, repeated gaps or queue caps were
removed. These are controlled timing results, not a claim about speaker audibility.

### Opt-in timing capture

`trace_server.exs` launches the canonical OrderDesk application with a validation
recorder. This is instrumentation, not application business logic or a library
runtime dependency. From `examples/order_desk`, with its vendored Parlora refreshed:

```sh
PORT=4000 ORDER_DESK_TYPESAFE=1 PARLORA_BROWSER_OFFLINE=0 \
PARLORA_AUDIO_TRACE_DIR=/tmp/parlora-browser-audio-trace-my-run \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run \
  ../../validation/browser-gap-20260921/trace_server.exs
```

Use a new output directory per server launch. The recorder keeps 8,192 numeric
telemetry entries and 16 completed gap records in ETS, plus at most 16 rolling
JSON reports on disk. A single periodic writer performs disk work away from media
processes. It records `session_id`, same-VM monotonic `at_us`, provider receive/read,
output pipeline frame/tick/pressure, and browser source/silence observations.
Reports include up to one second before the gap and available events up to 100 ms
after it; this trailing window is best-effort, not a wait for future events.
`earliest_retained_at_us` identifies the retained history's lower bound. Long gaps
or high event volume can overwrite earlier data. A process crash before the next
250 ms flush can lose a report; this is development evidence, not durable audit.

Interpretation text, PCM, authentication headers and keys are not recorded.
Provider telemetry records when decoded audio is handled locally; it cannot
separate remote generation delay from network delay before receipt. Per-tick
playout availability is sampled, so it also does not give an exact channel-write
arrival time. The aligned transfer events narrow that interval.

The running port-4000 server uses
`/tmp/parlora-browser-audio-trace-20260921-1330`. The user's order database is
preserved. Restarting through the normal `scripts/browser.sh` remains supported
and does not turn on file tracing.

### Validation of the correction

- Full library `mix ci` on macOS and Linux: **204 passed, 3 excluded**, with native
  checks, Credo/ExSlop, zero-clone ExDNA, Credence and Dialyzer.
- Rebuilt-package OrderDesk tests on macOS and Linux: **130 passed** on each.
- Browser.Media controls verify separated durations, deadline/pressure/disabled
  release, partial close, clear/reset, and forwarding through signaling.
- Seven replay reports were flushed and checked through the opt-in recorder.
- Offline macOS Chrome with tracing enabled passed three media/control/reconnect
  cycles, permission/origin rejection, and signaling-loss cleanup. It reported no
  packet loss, concealment or steady inserted silence. See `browser-fix-results.json`.

No new live GPT-Live or human listening test is claimed. The earlier call's exact
initial shortage remains unproven; the next instrumented call can provide the
previously missing timing evidence.
