# Full-cushion recovery investigation — September 21, 16:01 call

Investigated implementation: `d376f6f`. The diagnosis below describes that version.
The implemented correction and its validation are recorded at the end.

The browser call ran approximately 16:01:51–16:03:20. Six backend requests completed
and their results were accepted. It corrected 124 to 123, read items and saved
instructions, and announced the confirmed draft save. Browser observations and
server logs contained no failure/overflow event; `/health` reported zero sessions
after disconnect. This investigation concerns its remaining 120 ms PCM gap.

## Root causes and contributing delay

Gap 2 has substantial source peaks immediately before/after (3,776 / 3,936 on
signed 16-bit PCM). The browser media path inserted twelve 10 ms silent blocks.
This demonstrates software-inserted silence between nonzero source samples;
it does not identify syllables or prove what was heard. Thirteen other retained
gaps bordered zero or very small samples; their counters alone do not establish
speech interruption.

### 1. Arrival jitter exhausts the available cushion

Provider messages carry 4,800 bytes: 100 ms of 24 kHz mono PCM16. The last arrival
before the gap was at -106.938 ms; the next arrived at +8.048 ms, **114.986 ms apart**.
A previous arrival interval in the retained second was 147.540 ms. The pipeline
and channel had drained their available source by time zero.

These are timestamps inside the local provider handler. They establish locally
unavailable source, but cannot distinguish remote model generation, network
jitter, or delay before that handler. Calling this specifically an OpenAI service
or network defect would exceed the evidence.

### 2. Polling and output-clock phase add approximately 12 ms

| Event | Milliseconds from first inserted-silence block |
| --- | ---: |
| Browser output has no source | 0.000 |
| Next provider batch handled | 8.048 |
| Pipeline reads available provider bytes | 14.898 |
| First frame written to channel | 14.917 |
| Browser output first observes available source | 19.996 |
| Entire first batch has reached channel | 33.018 |
| Minimum refill interval has elapsed, queue still only 4,800 bytes | 80.010 |
| Second provider batch handled | 90.885 |
| Channel fills to 9,600 bytes | 113.046 |
| Browser resumes source | 119.960 |

`AudioPipeline.forward/1` polls an empty source every `tick_ms` (default 10 ms).
The poll at +4.896 ms was too early; +14.898 ms found the returning batch.
The output tick at +9.999 ms was also too early; +19.996 ms saw the transferred
source. Thus the measured 19.996 ms unavailability at playout contains ~8.048 ms
before the provider handler sees the batch and ~11.948 ms afterward. It is not
20 ms entirely attributable to remote delivery.

Recorded output-pipeline work was at most 722 microseconds and tick lateness at
most 2,436 microseconds during the gap. The trace does not support a 100 ms stall
in that pipeline. Ten 10 ms frames move through each received batch promptly.

### 3. Recovery target is coupled to maximum queue capacity

`Playout.new/2` sets `recovery_bytes` to the channel's **capacity**, 9,600 bytes
(200 ms). `buffering?/3` releases recovery only when both half the deadline has
elapsed and that full occupancy has been reached, or the full deadline expires.
Upstream pressure may separately release earlier.

The first returning batch supplied only 100 ms of audio. At +80 ms the default
60 ms minimum refill interval had elapsed, but the full-queue condition was false.
Recovery therefore kept generating silence until the second batch filled the
queue at +113.046 ms and the next output tick resumed at +119.960 ms.

This is why the previous fix did not remove this gap: it allowed earlier release
for a **full** channel; it did not separate a sufficient refill target from the
maximum storage bound. It operates as implemented, but conservatively holds
usable source while waiting for a second batch. The actual recovery contribution
was **99.964 ms**, not just the 60 ms minimum. It did release before the full
120 ms deadline measured from source return.

There were no blocked pipeline ticks or recovery-pressure release events in this
interval. The provider queue drained normally. This was neither overflow nor
slow draining of an already full channel.

## Reproduction

`gap-2.json` is the retained numeric trace from the call; it contains no raw PCM
or credentials. `replay.exs` executes production Browser.Media, Playout, and Opus
against the recorded channel-write/output schedule, using synthetic PCM. It
asserts exact production duration, inserted-silence count, source-unavailable
and recovery times, and resume occupancy. All supplied source bytes are consumed
when drained. The controls change only internal replay state, not runtime defaults.

| Replay policy | Inserted silence | Source unavailable | Recovery wait |
| --- | ---: | ---: | ---: |
| Current full-channel threshold | 120 ms | 19.996 ms | 99.964 ms |
| Diagnostic 100 ms refill threshold, same 60 ms minimum | 80 ms | 19.996 ms | 60.014 ms |
| Diagnostic disabled recovery | 20 ms | 19.996 ms | 0 ms |

Results are retained in `replay-results.json`.

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
  mix run validation/browser-cushion-20260921/replay.exs
```

## Fix direction and limits

Separate the bounded refill target from maximum queue capacity and evaluate its
minimum wait against measured arrival patterns. Keep overflow/backpressure
bounds, source order, short-tail behavior and clear/epoch handling. Polling phase
is a smaller, separate latency contribution; a source-availability wakeup would
need its own scheduling and busy-loop regression checks.

Neither diagnostic control is a production recommendation yet. The recording
contains only the retained local window. Earlier jitter fixtures reproduced
additional starvation when playback resumed too early, so any revised rule must
pass those fixtures, the burst/overflow controls, and a fresh listening call.
No physical recording or new live model call was made here.


## Implemented fix

`Playout.new/2` now derives a base recovery target of **min(100 ms, recovery
deadline)** rather than the entire queue capacity. The deadline remains bounded
by the configured initial cushion, 200 ms, and the configured queue duration.

- When source returns after a shortage of at most half that deadline, the base
  target is sufficient. With defaults this means a 100 ms target for shortages
  up to 60 ms.
- Longer shortages double the target, capped by queue capacity. With defaults
  this means 200 ms after a shortage longer than 60 ms.
- Resumption still requires half the deadline to elapse, or the full deadline
  releases the remaining short tail. Pressure release may act sooner. Zero
  buffering, clear/reset, epoch handling, and queue admission bounds are unchanged.

A fixed smaller target was tested first. Both 60 ms and 100 ms fixed targets
reintroduced the second gap at source offset 2,200 ms in the older starvation
fixture. Increasing the target after longer shortages preserves the original
single-gap expectations at offsets 1,200 ms and 10,100 ms in the two recorded
jitter fixtures. Their sample-order, capacity, and total-silence checks remain
intact. Queue capacity is only a cap on the target, rather than its definition;
unit tests cover both 200 ms and 400 ms storage with identical recovery behavior.

### Measured result

The production replay now inserts **80 ms** of silence for the latest gap,
compared with **120 ms** for the historical full-queue rule:

- Source unavailable at output: 19.996 ms, unchanged.
- Recovery wait: 60.014 ms, down from 99.964 ms.
- Source resumes with 4,800 bytes queued instead of waiting for 9,600 bytes.
- Every supplied source byte is preserved; the queue cap remains 9,600 bytes.

`fixed-replay-results.json` records the historical/current/diagnostic controls.
The earlier `replay-results.json` retains the investigation before implementation.
The production regression in `test/recorded_recovery_test.exs` checks exact
historical reproduction, the new 80 ms result, source-unavailable time, release
reason, occupancy and source-byte preservation. The earlier gap replays remain
120/140 ms; the longer-shortage guard avoids undoing those fixes.

The overflow replay exercises the new constructor target at ten output-clock
phases. All preserve 52,800 source bytes without overflow; the historical 200 ms
hold continues to reproduce overflow at all ten phases. Browser diagnostics also
verify that short-shortage release is labeled `queue_ready`, while long-shortage
short tails still use the finite deadline and pressure release remains effective.

### Validation and running app

On macOS and Linux (`ssh linux`), pinned Elixir 1.20.4 / OTP 29.0.6:

- Root `mix ci`: **208 passed, 3 excluded**; native checks, Credo/ExSlop, ExDNA
  zero-clone budget, Credence and Dialyzer all pass.
- Packaged-library OrderDesk example: compile with warnings-as-errors and
  **143 tests passed** on each platform.
- Logs: `macos-ci.log`, `linux-ci.log`, `macos-example-tests.log`, and
  `linux-example-tests.log`.

The idle browser server was restarted on `http://localhost:4000` with the updated
package, preserving its SQLite data. Numeric audio traces now go to
`/tmp/parlora-browser-audio-trace-cushion-fixed`. Health reports zero sessions.

This change does not remove unavailable source or the polling contribution.
No new physical audio or listening result is claimed. The 80 ms value is the
result for this recorded schedule, not a guarantee for every future call.
