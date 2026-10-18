# Selective speech recovery — October 4, 2026

The reported GPT Live interruptions combined late source audio with an additional
wait for a second 100 ms receipt. The two exact clock windows contained 89,979
and 110,025 microseconds without source, followed by 99,962 and 91,004
microseconds of additional recovery waiting. The learned target was already
200 ms. Transfer and render scheduling did not explain that added waiting.

Established speech can now restart a complete 80–200 ms locally timed receipt
after a 20 ms settling interval. Eligibility requires a learned target above the
floor, an ordinary shortage within the configured cap, a nonquiet queue head,
and a qualifying quiet passage 200–1,000 ms back in source position. Onsets,
smaller fragments, severe stalls and unknown clocks retain their existing rules.
The 120 ms startup floor, sample order, queue limits and media clock are unchanged.

An early restart records the conservative time saved against the ordinary
deadline. Extra waiting during qualifying quiet source repays that reserve before
another selective restart. A momentarily full queue does not clear this debt.
Restoration accounts separately for when the original quiet policy would have
released; a restoration-only hold does not add another ordinary 60 ms wait.
Quiet waiting remains bounded by the adaptive ceiling (at most 200 ms).
Pressure still releases immediately, retaining unpaid debt. Clear, discontinuity,
incompatible clocks and idle receipt boundaries remove the old evidence.

## Recorded evidence

Fixtures contain relative receipt/render times and source peak envelopes, with
no original PCM, captions, session IDs or credentials. Constant sample proxies
preserve the quiet/nonquiet classification but do not recreate the waveform.
Unknown unrendered tails are represented as nonquiet and excluded from known
boundary claims. A nonquiet gap has both adjacent 10 ms peaks greater than 64.
This flags a possible interruption, not proof of speech or audibility.

The focused regression preserves the recorded clock windows and drains every
sample through finite queues and PCM staging. At the recorded render timing:

| Window | Previous gap | Current gap | Source samples |
| --- | ---: | ---: | --- |
| First reported stall | 189.941 ms | 111.018 ms | Preserved |
| Second reported stall | 201.029 ms | 140.034 ms | Preserved |

All ten render phases pass the focused checks. Source-unavailable time remains;
a sample-preserving queue cannot manufacture missing provider audio.

The full comparison replays three complete arrival timelines through production
AudioPipeline, finite adapter queues, PCM staging and Playout. It pairs each of
ten render phases against the frozen `6de130a` policy in `reference.exs`:
**30 paired comparisons / 60 replay cases, all passing**. The earlier two calls
retain their playback results. In the newest complete call, nonquiet-boundary
gap counts are 4–9 before and 4–8 after; total flagged gap time falls from
440–550 ms to 240–390 ms. Maximum source age remains 284–293 ms, and total
inserted silence and startup timing remain unchanged. At phase 1,000 us the two
targeted source positions shrink from 120/200 ms to 70/130 ms. These whole-call
numbers differ from the exact windows because the replay rebuilds the complete
causal queue timeline with a synthetic render clock.

Paired gates require no increase in nonquiet gap count, total duration or maximum
duration, byte integrity and order, complete drain, bounded queues, cleanup,
unchanged startup, no more than 200 ms extra inserted silence per call, and
maximum source age <=400 ms. These aggregate gates do not require every gap to
stay at the same source position: for example, phase 1,000 us moves a 20 ms gap
to a later passage while eliminating another 100 ms interruption. No claim is
made that every remaining or relocated gap is inaudible. The complete-call test
keeps the previous regression at that render phase in the normal test suite.

## Broader controls

Nine arrival patterns, three seeds (7, 42, 91), three render phases, continuous
nonquiet PCM and recurring quiet passages, paired policies: **324 cases**.
All safety and paired nonquiet-gap gates pass. Maximum extra inserted silence
is zero, and maximum source age is 292 ms. Nonquiet recovery waiting remains
bounded by 120 ms plus a render tick. Proactive quiet restoration is checked
against the separate 200 ms ceiling plus a tick; its source-unavailable interval
is zero. Focused tests cover repayment accounting, early full-cushion readiness,
restoration-only holds, pressure release, small/severe returns, stale/missing
quiet evidence, unknown clocks, idle boundaries and clear/reset behavior.

## Reproduce

Run from the repository root with the pinned toolchains:

```sh
MIX_ENV=test mix run validation/speech-recovery-20261004/replay.exs
MIX_ENV=test mix run validation/speech-recovery-20261004/controls.exs
mix test test/speech_recovery_test.exs test/speech_recovery_recorded_test.exs test/audio_benchmark_test.exs
```

`summary.json`, `controls-summary.json` and `verification.json` retain compact
results. The scripts regenerate the ignored detailed `comparison.json` and
`controls.json`. Earlier captures are reused from `../quiet-refill-20261004`.
These replays omit Opus decoding, browser jitter buffering, physical playback
and arbitrary OS/network behavior. A fresh listening test remains necessary;
the tests establish a bounded recovery improvement, not universal gap-free audio.
