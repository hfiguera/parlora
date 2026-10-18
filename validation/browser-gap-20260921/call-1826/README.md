# September 21, 18:26 browser call: adaptive recovery regression

The user reported many audible hiccups. The conversation completed successfully,
but that does not make this an audio pass. Session: `h8Sjqhz2qRp4hZGZitmsnMvd`.
The original investigation changed no production code. The correction and its
validation are recorded below; the failing evidence remains preserved.

## Confirmed cause

The uncommitted adaptive `Parlora.Playout` change accumulates each observed
shortage into the retained refill target. It decays by only 10 ms of target per
second, resets history only for a single shortage of at least 250 ms or explicit
clear, and treats shortages bordered by near-zero PCM the same as other shortages.
This measures neither recent packet-arrival jitter nor speech continuity.

Targets reconstructed by executing production code across all twelve recorded
recoveries were approximately 90, 84, 91, 178, 193, **200**, 200, **200**, **200**,
200, 173 and 184 ms. The first five recoveries had boundary peaks of 0 or 1;
their shortages still raised the target inherited by later nonquiet audio.
Near-zero boundaries do not prove the entire surrounding interval was silence.

For gaps 6, 8 and 9, a 100 ms source chunk returned but the accumulated target
required 200 ms. Playback therefore emitted zero PCM while waiting for the
target or deadline, even with 70–100 ms already queued. These were ordinary
shortages below 120 ms: the separate severe-stall minimum timer was **not** the
cause. All three released by deadline with only 100–110 ms queued, below the
learned target. The target was not achieved and yet was retained for later gaps.

| Gap | First tick seeing source | Additional recovery wait | Total recorded gap | Current policy with prior learning removed |
| --- | ---: | ---: | ---: | ---: |
| 6 | 60.104 ms | 89.906 ms | 150.010 ms | 70.118 ms |
| 8 | 19.983 ms | 49.977 ms | 69.960 ms | 30.094 ms |
| 9 | 39.952 ms | 60.050 ms | 100.002 ms | 50.037 ms |

The controlled comparison holds each gap's recorded queue-empty starting point,
accepted-frame arrivals and output tick times constant. It isolates the added
wait caused by retained learning. It is **not** a whole-call counterfactual:
earlier resumption changes later queue occupancy, so these shorter intervals
are not a validated replacement policy. Source bytes are synthetic placeholders;
there is no speaker or receiver recording in this evidence.

## Source timing is a separate contributor

The adjacent provider arrivals carried 100 ms of PCM but were separated by
247.263, 160.539 and 190.722 ms for gaps 6, 8 and 9. The queue exhausted before
the next arrival. Actual provider receipt occurred 53.717, 14.456 and 36.512 ms
after the corresponding empty observation, earlier than the next playout tick.

The first positive provider reads followed receipt by 0.017, 0.041 and 0.025 ms.
The first accepted channel frames followed receipt by 0.077, 0.085 and 0.124 ms.
Maximum pipeline tick lateness in the retained windows was 3.361, 5.438 and
5.438 ms. Thus the trace does not support slow queue draining or a long scheduler
stall as the explanation for these 70–150 ms gaps. It does show late arrivals at
our provider boundary; it cannot separate OpenAI generation delay from network
delivery delay.

## Reproduction and test coverage gap

`trace-excerpts.json` preserves all twelve completed gap summaries and each
gap's accepted-frame and playout timings through its recorded recovery. For
gaps 6/8/9 it also retains surrounding provider receive/read and pipeline tick
measurements. No raw caller audio or credentials are included.

Run from the repository root, on the pinned toolchain:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  mix run --no-start validation/browser-gap-20260921/call-1826/replay.exs
```

The replay reproduced **all 12 durations exactly** with the observed production
Playout implementation (original module SHA-256
`8c16954bcdbb1de5d8bb9ffc402a7d52e70a4dd249d87daccb6b85eac6ee31fe`).
That policy is preserved as `RecordedAdaptivePlayout` in `observed_playout.exs`.
The replay asserts that correspondence for the preserved policy, then separately
evaluates the current implementation. Original results are in `replay-results.json`;
post-fix results are in `fix-results/recorded-replay.json`.
The script also compiles the previous policy from commit `7816663` under a
separate module name. A null comparison means the recorded excerpt ends before
that alternative releases, not that it would never release.

The existing normal benchmark runs use three seconds of bounded jitter, which
does not reproduce this history of shortages. The twenty-second cumulative-delay
control permits up to 600 ms total inserted silence; reducing the number of
recoveries while extending individual pauses can still pass. Adaptive unit tests
verify learning, decay and bounds but do not reject the delay amplification seen
here. Passing those checks was insufficient evidence of audible improvement.

## Correction

Removed the accumulated history and its decay/reset thresholds. Recovery uses
only the current shortage plus 20 ms of headroom, retaining the queue/target caps,
pressure release, short-tail deadline and severe-stall settling guard. This also
retains the earlier correction that releases a ready cushion immediately after
ordinary shortages instead of adding a half-shortage minimum timer.

The three recorded nonquiet-boundary gaps now replay at 70.118, 30.094 and
50.037 ms, adding approximately 10 ms after source first becomes available.
Production Browser.Media replay tests also verify source byte preservation.
Those isolated windows cannot establish the effect on later gaps, so an additional
full-sequence regression runs twenty seconds of source audio through production
AudioPipeline, provider OutputBuffer, AudioQueue and Playout, with continuous state
and ten different output-clock phases. It includes repeated 160–247 ms arrival
intervals for 100 ms packets and alternates quiet/nonquiet PCM.

Each ordinary shortage (<=80 ms) in that fixture must add <=30 ms of recovery
wait, with exact PCM equality and unchanged finite queue bounds. The observed
policy **fails all ten phases**, reaching 100 ms of added wait. The corrected
policy **passes all ten**, reaching at most 10 ms of added wait. This is a
negative control for the new per-gap gate, not an assertion that all source
shortages have disappeared.

Reproduce the full-sequence comparison in separate Mix VMs:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  mix run --no-start validation/browser-gap-20260921/call-1826/sequence.exs \
  observed /tmp/observed-sequence.json
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  mix run --no-start validation/browser-gap-20260921/call-1826/sequence.exs \
  current /tmp/fixed-sequence.json
```

The `observed` command deliberately substitutes the preserved failing policy in
its own VM only and exits successfully only if every phase fails the new gate.
Never load that diagnostic into a live application.

See [fix validation results](fix-results/README.md) for platform checks. Arrival
delays at the provider boundary remain possible. This fix removes local
amplification; it cannot generate source audio that has not arrived. The new
live server still needs a listening call before claiming that this particular
user-visible problem is fully resolved.
