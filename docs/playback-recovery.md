# Bounded PCM playback recovery — 2026-09-20

## Generated-audio overload recovery — October 4, 2026

GPT Live now uses a separate 2-second receive-storage ceiling and a 3-second
residence limit. The playback policy below retains its 120 ms floor. Ordinary
bursts preserve all samples; hard overload replaces only the voice transport,
keeps the caller connected, and asks for a repeat before delivering held results.
See [output recovery](output-recovery.md) for the contract, bounded reconnect,
input discontinuities, backend action safety and validation limits.

## Current adaptive policy — October 4, 2026

Browser and LocalAudio default to `playback_buffering: :adaptive` with a
120 ms floor (`playback_buffer_ms`) and a ceiling of min(200 ms, queue duration).
`playback_recovery_ms` independently limits additional ordinary recovery waiting to
120 ms by default; valid values are 0–200. Quiet restoration after an early speech
restart has a separate bound described below. A zero initial cushion disables all
buffering. `playback_buffering: :fixed` retains a constant startup target and the
shortage-based recovery rule, with the separately configured wait cap.

The estimator groups admitted fragments by their original local receipt
timestamp and stream/generation. It compares receipt spacing with accumulated
source duration, using the lowest recent transit as a baseline. Recent lateness
samples yield a 95th percentile plus 20 ms of headroom. Both histories retain at
most 128 receipt groups or five seconds of source audio, whichever is smaller.
An empty queue can increase the target immediately from the latest lateness;
otherwise the percentile controls growth. Reductions are at most 10 ms after
five seconds of qualifying stable source audio, including across short replies.
Idle wall time cannot lower the target.

Startup/recovery latch the learned target once, without changing it during an
active wait or continuous playback. Once the target grows above the configured
floor, recovery requests the full latched target, capped by channel capacity.
At the floor it uses shortage + 20 ms, capped by the latched target and capacity.
This rebuilds learned headroom rather than restarting repeatedly with one
provider chunk. Its minimum settling wait remains
min(max(0, shortage − recovery cap), recovery cap / 2), and its deadline remains
min(shortage + 20 ms, recovery cap). Queue pressure can release it sooner.
Short tails always drain without another receipt. No samples are discarded or
time-stretched to shrink the target; the media clock and all queue limits remain
unchanged. Acoustic silence counts as source audio.

Adaptive playback can also rebuild headroom **during a very quiet source passage**.
After nonquiet audio has played, at least 20 ms of consecutive source PCM and
all of the next queued 10 ms must have absolute samples <=64 (about -54 dBFS).
With valid local receipt evidence, a learned target above the floor, and less
than half that target queued, playback holds the quiet passage until the target
is queued or at most min(60 ms, recovery cap). It holds at most once per quiet
passage, re-arming after nonquiet source or a real starvation. This conservative
amplitude gate is not a speech recognizer; low-level speech and noise can still
qualify. It preserves the quiet PCM too, rather than deleting silence or changing
sample timing. Holding quiet audio is deliberately a latency tradeoff.

After a brief real shortage near an onset, recovery may resume available nonquiet
PCM sooner: the last qualifying quiet passage must be within 200 ms of source,
the observed shortage must be <= recovery cap / 3 (40 ms by default), and at
least max(80 ms, the latest admitted local receipt group's duration) must be
queued. This exception uses bounded local evidence, not a prediction of the
next arrival. For an established nonquiet passage, an ordinary shortage greater than one
third of the recovery cap and no longer than that cap can also resume sooner.
With a learned target above the floor, a complete locally timed receipt group
of 80–200 ms must be queued and its first 10 ms must be nonquiet. The last
qualifying quiet passage must be more than 200 ms and at most one second back
in source position; an onset retains its existing conservative recovery. Recovery
allows a settling interval of min(20 ms, recovery cap) after source returns,
then resumes that group rather than waiting for the full learned target. This
adds a small timing margin without turning a 100 ms returning chunk into
another 100 ms of silence.

The restart records the time saved against the ordinary capped deadline as a
conservative reserve debt. Another selective restart is blocked until extra
waiting during qualifying quiet PCM repays it. A restoration can start below the
full learned target, rather than below half the target. It starts repayment when
an ordinary quiet refill would release (full cushion or its deadline), or
immediately if the hold exists only for restoration. Total waiting is bounded
by the adaptive ceiling, at most 200 ms; the default ordinary 120 ms recovery
cap still applies to nonquiet shortages. Pressure can release immediately and
unpaid debt remains. All quiet source samples are preserved too. This moves
reserve rebuilding into quieter passages and can add latency there; it is not
silence detection or a guarantee about the next provider receipt.

Smaller returns, severe shortages and unknown clocks retain the
ordinary recovery fallback above. Pressure still releases immediately; clear,
clock/stream changes and idle receipt boundaries reset quiet evidence and debt.

The [speech-recovery comparison](../validation/speech-recovery-20261004/README.md)
covers both reported stalls, three complete captured arrival timelines at all
ten render phases, and 324 paired jitter/shortage control cases. The complete
call regression is also part of the test suite. These peak-envelope replays
verify source preservation and queue behavior, not perceived audio quality.

The [quiet-refill comparison](../validation/quiet-refill-20261004/README.md)
replays two complete arrival timelines using recorded source peak envelopes and
all ten render phases. It measures interruptions at source positions, preserves
all source bytes, and records the extra delay. These synthetic envelope replays
are not listening tests and do not establish that every gap is inaudible.

Clear/suppression and source discontinuities restart the receipt baseline while
preserving the learned target. Stream/generation changes, regressing timestamps,
and incompatible clocks also restart measurement. Learning requires timestamps
labeled `:local_monotonic`; provider/unknown clocks cannot supply local arrival
measurements. A receipt gap exceeding the previous receipt's audio duration by
at least one second starts a fresh timing baseline. After an empty output queue
for at least one second, returning audio uses startup buffering. These are idle
heuristics: without explicit utterance markers, a shorter between-reply pause can
still count as delivery variation, and a long mid-utterance stall can count as
idle. Neither changes source preservation or the bounds.

Both channels' `observations/1` expose the latched `playback_buffer_ms`, learned
`playback_target_ms`, floor/ceiling, independent `recovery_buffer_ms`, mode,
increase/decrease counts, idle/clock reset counts, and `quiet_refills`. These are local queue
observations, not proof of audible playback. See [the comparison and receiver
validation](../validation/adaptive-playout-20261004/README.md).

The greeting follow-up retains [two complete numeric arrival timelines and a
controlled comparison](../validation/greeting-recovery-20261004/comparison.json).
The captured greeting regression verifies source ordering and consolidates three
later 10 ms interruptions into an earlier bounded refill pause. Replay uses
synthetic samples; it does not establish perceived audio quality.

The [shorter-wait investigation](../validation/recovery-wait-20261004/investigation.json)
covers six ordinary-shortage wait ceilings, ten render phases, three manual
arrival traces, three provider reference traces, and six synthetic scenarios
(720 cases). All safety gates pass. A 40 ms ceiling reduces the latest call's two
isolated audible gaps from 190/180 ms to 140/130 ms, but creates 4–13 more
whole-stream gaps than the current rule, depending on render phase. These counts
include gaps at quiet source boundaries; they are not audible-defect counts.
Total inserted silence changes by at most 10 ms in that call. No shorter global
ceiling was applied: it redistributes pauses without establishing an audible
improvement. The opt-in browser trace now records per-block source peaks and
rendered source positions to support a comparison at the same source locations
without retaining audio samples.

The sections below retain the earlier fixed-policy measurements and corrections.

**Follow-up correction:** a subsequent browser call exposed a burst/recovery
interaction. Recovery now releases early under measured upstream pressure while
preserving the bounded wait on the earlier starvation traces. See
[the reproduction and correction](browser-recovery-overflow.md). Measurements
below describe the original recovery change; the follow-up report records the
additional validation and its limits.

**Current September 21 correction:** recovery scales with the shortage observed
at playback, without the former fixed 60 ms minimum or abrupt target doubling.
The configured upper bound remains min(initial cushion, 200 ms, queue duration),
120 ms by default. From the first returning source frame:

- Queue target: shortage + 20 ms of PCM, bounded below by 20 ms and above by
  twice min(100 ms, configured bound), then capped by channel capacity.
- Minimum hold: half the shortage, capped at half the configured bound.
- Deadline: shortage + 20 ms, capped at the configured bound. Short tails resume
  at this deadline; upstream pressure can release sooner. Zero disables buffering.

The pipeline can also arm an optional, one-shot provider readiness notification
when a channel-paced output source is empty. Arrival wakes it immediately instead
of waiting for the next empty poll. Obsolete notifications and cancelled timer
messages are ignored; providers without this callback retain polling.

The latest three recorded gaps replay as **20/40/110 ms instead of 80/90/190 ms**
with the same downstream arrival times and preserved source samples. Older
repeated-gap and overflow regressions remain covered. This replay isolates
recovery and excludes the new readiness wakeup; it is not a listening result.
See [the investigation and fix](../validation/browser-recovery-threshold-20260921/README.md).
Measurements below describe the original fixed-200-ms implementation.

## Changes

LocalAudio and Browser now declare `output_pacing: :channel`. Their native/RTP
clock controls actual playback; the session pipeline refills the channel queue
in bounded bursts of at most 20 frames per turn. Readiness and queue-space hints
wake transfers immediately; periodic polling remains the fallback. A drained burst
without readiness support retains a 1 ms follow-up poll; empty and backpressured
transfers otherwise poll at the normal 10 ms interval. This
allows delayed batches to rebuild the playback cushion promptly. Telephony,
provider input and custom channels keep their existing pacing by default.

Both PCM channels default to a **120 ms initial cushion**, configurable through
`playback_buffer_ms`. Initial playback starts when that much PCM is available,
or after that interval from the first available frame for a short tail.

In the original implementation, after starvation playback waited **200 ms from the next available frame** before
resuming, capped by the configured queue duration. A full channel by itself does not end that recovery wait: it does not establish
steady delivery. When provider and pending pipeline audio reach the pressure
threshold, the pipeline releases recovery early so playback can drain. This reduces repeated interruptions at the cost of a longer single
pause. Setting the cushion to zero disables buffering/recovery waiting. Clear
resets recovery state, converters and queues as before; short tails remain
playable without another incoming frame.

Queue bounds are unchanged: channel PCM 200 ms, provider receive 700 ms, pending
pipeline batch at most 20 ms. Admission still uses backpressure and the 500 ms
deadline. Temporary blocked transfer ticks are now expected when prompt refill
fills the channel queue. They do not by themselves indicate slow playback.

## Historical recorded-arrival regression

The measurements below describe the earlier refill implementation. The current
whole-stream replay also models browser staging and all ten render phases, so its
gap timings differ. See the [October 3 hardening evidence](../validation/playout-hardening-20261003/README.md)
for the current baseline comparison, retained failures and limits.

`test/playback_refill_test.exs` feeds captured provider arrivals through production
`AudioPipeline`, bounded in-memory adapters and `Playout`. A deterministic device
clock consumes 10 ms per tick; it preserves every source byte in order. It models
playback without CPAL conversion, OS scheduling or physical speakers, so its gap
timings differ slightly from a live native run.

| Original arrival fixture | Previous policy | Final policy |
| --- | --- | --- |
| Initial buffering | 50 ms | 110 ms |
| Interior starvation transitions | 3 | 1 |
| Inserted silence during arrivals | 320 ms | 300 ms |
| Remaining gap, position in source PCM | 300 / 1,200 / 2,200 ms | 1,200 ms |
| Peak channel queue | 2,880 bytes | 9,600 bytes |

The retained signal-level evidence identifies the remaining 1,200 ms boundary as
silent/nearly silent. The two nonzero boundaries no longer have inserted silence
in this replay. Initial buffering increases by **60 ms**, not an unbounded delay.

A longer live trial with prompt refill but the old restart rule still reported
a 70 ms gap between substantial audio after an earlier silent gap. Its log and
arrivals remain in `playback-refill-trial.log` and `refill-trial-arrivals.json`.
Replaying those same arrivals with the final bounded recovery changes two modeled
gaps to one at source position 10,100 ms (silent in the live measurements). Total
inserted silence increases from 320 to 390 ms: **70 ms more waiting at the earlier
pause prevents a later interruption**. This is the recovery tradeoff, not a claim
that all measures of latency improved.

Other regressions verify short-tail recovery, clear/reset, zero buffering,
capacity-capped recovery, prompt refill, frame order under backpressure, and
resumption without losing pending frames. Existing tests cover suppression,
browser media pacing/encoding, native cleanup and session lifecycle.

## Final live retest

The final synthetic PCM call completed and finalized usage. Measurements retained
in `playback-recovery-live.log` and `playback-recovery-summary.json`:

- 62 provider chunks; peak receive queue 4,800 bytes / 100 ms.
- Zero provider-dropped bytes or overflow.
- One starvation event: neighboring source peaks **0 and 1**, with 290 ms of
  generated silence spanning the arrival gap and recovery wait.
- No observed starvation between substantial source audio in this run.
- 207 temporary blocked transfer ticks while the bounded channel queue filled;
  no backpressure timeout or failed call.

This is a new, shorter live conversation. The longer recorded-arrival test above
controls for differing live output. The starvation counter still measures empty
source queues, not confirmed speech loss. Neither this probe nor the replay proves
physical playback quality or absence of gaps under arbitrary network stalls.

## Validation

Full `mix ci` passes on macOS and Linux: **180 tests passed, 3 excluded**, plus
native tests and all configured quality checks. The standalone consumer passes
107 tests on each platform with the updated library. Evidence is retained under
[validation/pcm-overflow](../validation/pcm-overflow/). No physical device, carrier
call or new live browser call is claimed by this change.
