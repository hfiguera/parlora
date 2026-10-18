# Quiet source refill and selective onset recovery — October 4, 2026

The previous rule could hold available nonquiet PCM while trying to rebuild a
learned 200 ms cushion after a short source shortage. A global shorter recovery
wait reduced some gaps but created more interruptions elsewhere. This change
instead uses conservative source amplitude and local queue/receipt evidence.

In adaptive mode, with a learned target above the configured floor, the controller
can insert a hold during very quiet source PCM when occupancy falls below half
the target. It requires prior nonquiet source, at least 20 ms of played quiet
PCM, a complete quiet 10 ms queued head, and local receipt evidence. Every sample
must have absolute amplitude <=64 (about -54 dBFS). The hold ends on a full cushion
or after at most min(60 ms, recovery cap). It can occur once per quiet passage,
re-arming after nonquiet audio or a real starvation. Quiet PCM is preserved too.
This amplitude gate is not a speech detector; low-level speech can qualify.

After a real shortage <= one third of the configured recovery cap, nonquiet source
near a qualifying quiet passage can resume with at least max(80 ms, the latest
admitted receipt group's duration) queued. The last quiet passage must be within
200 ms of source position. This trades a little headroom for prompt continuation,
without claiming knowledge of the next arrival. Longer shortages and small
returns retain the ordinary recovery fallback. Initial floor 120 ms, learned
ceiling 200 ms, queue capacities, pressure release and media clock are unchanged.
Unknown clocks, clear, source discontinuities and idle receipt boundaries reset
the evidence. Fixed mode and disabled buffering retain their behavior.

## Captured-call comparison

Two closed, untruncated numeric traces supply complete arrival timelines and
contiguous per-block rendered source peak envelopes, with no clears or source
position discontinuities. Fixtures contain no original PCM, captions, credentials
or session IDs. Synthetic constant samples represent each recorded peak; this
preserves the quiet-gate classification but does not recreate the waveform or
permit a listening assessment. Unknown unrendered tails (110 and 100 ms) are
conservatively represented as nonquiet and excluded from known-level gap claims.

`replay.exs` runs production AudioPipeline, finite adapter queues, PCM staging and
Playout at all ten 10 ms render phases, paired against the frozen previous policy
in `../recovery-wait-20261004/reference.exs`. The benchmark's gap helper is annotated
with rendered source position; it does not change playback. Gaps are inspected
across the whole timeline, not just the reported live interruption. “Nonquiet”
means both adjacent 10 ms source peaks exceed 100, not proof of speech or audibility.

| Capture | Previous nonquiet gaps | Current nonquiet gaps | Extra inserted silence across the entire replay | Current maximum source age |
| --- | --- | --- | --- | --- |
| First level-instrumented call | 1–2, totaling 120–180 ms | 0 | 30–50 ms | 331–340 ms |
| Call with heard middle interruption | 1, 40–100 ms | 1, 30–40 ms | 80–90 ms | 258–290 ms |

All **20 paired comparisons / 40 replay cases** pass: byte integrity/order,
queue bounds, complete drain, cleanup, startup, cumulative delay and recovery
delay. Additional paired gates require no increase in nonquiet gap count,
total or maximum duration, unchanged initial playback timing, no more than
200 ms extra inserted silence per call, and maximum source age <=400 ms.
The old maximum source age was 238–257 ms and 201–206 ms respectively. Thus the
change moves some waiting into quieter passages and adds later latency; it does
not improve every latency measure. Source-unavailable time cannot be removed by
a sample-preserving queue. The remaining 30–40 ms interruption needs a new manual
listening test before making further playback-quality claims.

## Broader controls

`controls.exs` covers nine arrival patterns (steady, jitter, burst, variable,
scheduler delay, shortage, underproduction, late bursts, repeated shortages),
three render phases, continuous nonquiet PCM and recurring quiet passages,
paired old/current policies: **108 cases**. All benchmark safety gates pass.
Continuous nonquiet controls must match the previous policy's gaps, source age,
startup, inserted silence and rendered bytes exactly. These cases exercise queue
behavior; they do not simulate all networks, provider waveforms or physical devices.

Focused tests cover source preservation, quiet tails, early full-cushion release,
short recovery caps, pressure release, small/severe returning shortages, unknown
clocks, clear/discontinuity, numeric browser observations and collector privacy.
Quiet holds have zero source-unavailable duration and a separate `quiet_refill`
cause; selective resumption uses `speech_continuation`. Diagnostics retain numbers
and known classifications only, without audio.

## Reproduce

Run from the repository root with the pinned toolchains:

```sh
MIX_ENV=test mix run validation/quiet-refill-20261004/replay.exs
MIX_ENV=test mix run validation/quiet-refill-20261004/controls.exs
mix test test/quiet_refill_test.exs test/browser_diagnostics_test.exs
```

`comparison.json`, `summary.json`, `controls.json` and `verification.json` retain
final results. `candidate-variants.json` retains exploratory variants: shorter
quiet caps could move gaps elsewhere, while a 120 ms cap added excessive delay.
Those exploratory records are not final-policy verification. These synthetic replays omit browser jitter buffering, Opus decoding,
OS scheduling and physical playback. No PLC, time stretching, sample deletion or
DSP dependency is introduced. This is a bounded recovery improvement, not proof
of production readiness or elimination of audible interruptions.

## Manual follow-up before commit

The 15:59 call completed all five backend requests and accepted their results;
order 124 saved version 9. The user reported no audible choppiness. Numeric
observations nevertheless recorded nonquiet-boundary gaps of 90, 120 and 130 ms,
and 25 quiet holds. No provider-dropped audio or browser console error was
recorded. Smooth listening in that call does not establish that all measured
interruptions have been eliminated.

The next call ended at 16:13:16 with OpenAI `output_overflow`: 29,760 queued bytes
plus a 4,800-byte arrival exceeded the 33,600-byte (700 ms) provider queue. The
provider supplied approximately 1,000 ms of PCM over 262 ms. Output was draining
normally and quiet refill was inactive at overflow. An additional numeric-envelope
comparison at four render phases overflowed with both the frozen previous policy
and the current policy, at matching rendered source positions. This points to an
existing burst-capacity limitation rather than an overflow introduced by quiet
refill; it is not an arbitrary-network guarantee. The provider's existing failure
path clears queued audio and closes the call. Burst handling remains unresolved
and no overflow behavior was changed in this commit. Summary evidence is in
`verification.json`; full private diagnostic captures remain outside the repository.
