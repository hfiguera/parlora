# PCM playback-starvation investigation — 2026-09-20

## Finding

The reported counter mixes gaps that can affect speech with gaps during silence.
A new instrumented live PCM run reproduced three events, including **110 ms of
inserted silence between substantial nonzero audio samples during the reply**.
This is a real gap in the synthetic playback stream and a potential audible
glitch, although no physical speaker was used. It is separate from the corrected
synthetic-device clock drift and fatal provider overflow.

The observed cause is **uneven audio arrival exhausting the playback cushion**.
When its queue empties, `Parlora.Playout.take/4` resets playback and substitutes
silence. When frames arrive again, it waits for 60 ms of queued audio or a 60 ms
timeout before restarting. Because the pipeline forwards frames at playback
speed, this refill can extend the gap after provider audio has already returned.

For the 110 ms gap, two 100 ms provider chunks arrived together after a
198.659 ms interval. The pipeline had no source audio to forward for 109.967 ms.
The channel first received another frame 57.294 ms after starvation, then resumed
source playback at 109.116 ms. During that interval it generated eleven 10 ms
silence blocks. Local polling continued normally, with no added native underruns
and no pipeline backpressure. This is not evidence of a slow synthetic clock.

These are arrival times at Parlora's provider boundary. They cannot distinguish
network delay from upstream provider scheduling; the investigation does not
attribute the delay specifically to OpenAI or to the network.

## What the three retest events represent

Times are relative to this fresh probe's session start. Silence duration comes
from the actual byte counts sent to the converter, not rounded wall-clock gaps.
Peak levels are absolute PCM16 sample values (maximum 32,768) in the source blocks
immediately before and after the inserted silence. They are not speech detection
or exact word alignment.

| Event | Arrival interval for 100 ms chunks | Inserted silence | Source peak before / after | Assessment |
| --- | --- | --- | --- | --- |
| 1,955 ms | 128.574 ms | 70 ms | 252 / 1,712 | Nonzero audio on both sides; low-level tail before gap. Audibility unverified. |
| 2,922 ms | 238.640 ms | 120 ms | 0 / 1 | Silent/nearly silent boundary blocks; no evidence of a clipped syllable at this gap. |
| 4,043 ms | 198.659 ms | 110 ms | 3,536 / 1,456 | Substantial signal on both sides, during the reply; potential audible interruption. |

All three windows had zero increase in native output underruns. Their maximum
local poll gaps were 6.992, 7.043, and 8.110 ms respectively. Across the live run,
output ticks never blocked, the provider queue peaked at 9,600 bytes / 200 ms,
and the call completed with finalized usage. No provider overflow occurred.

## Why the event name is insufficient

`Playout` counts the transition from playing queued bytes to an empty queue.
It does not inspect speech, amplitude, or an authoritative end-of-speech marker.
Even a finite clip finishing normally triggers this counter on the next empty
read. Native callback underruns are a different event: here the callbacks can
continue consuming generated silence while the source queue is empty.

The local [GPT-Live conversation documentation](gpt-live-1/live-conversations.md)
also states that output WebSocket audio has no timing fields or audio-done event,
and transcripts are not exact word/playback alignments. Caption proximity alone
cannot establish whether a syllable was cut. A count of three therefore does not
mean three confirmed audible glitches.

## Original run versus the retest

The original `native-fixed.log` did not timestamp discontinuities or record
per-block signal levels. Its numeric trace shows 175.516, 174.974, and 199.416 ms
arrival intervals and approximately 70, 70, and 111 ms forwarding gaps consistent
with the three logged starvations. This supports delivery-jitter investigation,
but does not establish the precise acoustic position of each original event.

The table above is a **new run**, not a reconstruction of missing original audio.
`trace.exs` now records playout byte counts, peak levels and native poll counters;
the live probe timestamps discontinuities. Trace collection uses a bounded
30,000-entry queue with constant-time insertion so larger traces do not require
copying the entire retained history on every event. No raw audio or credentials
are retained.

## Reproduction and validation

Evidence in [validation/pcm-overflow](../validation/pcm-overflow/):

- `starvation-retest.log`: fresh live outcome and timestamped discontinuities.
- `starvation-evidence.json`: measured gap summaries and the first 3.5 seconds of
  provider, pipeline-forwarding and playout timings, relative to first audio.
- `starvation-macos-ci.log` and `starvation-linux-ci.log`: required checks.

`test/playout_starvation_regression_test.exs` uses synthetic sample bytes with the
recorded forwarding and playout timings. It reproduces all three starvation
transitions through the production `Playout`, checking every queue size, source
byte count and inserted-silence count. A control keeps identical playout timing
and the same 60 ms buffer, but feeds frames regularly: **zero starvations**.
The signal peaks are retained measurements, not inferred from synthetic replay.

```sh
mix test test/playout_starvation_regression_test.exs
```

Both replay tests and full `mix ci` pass on macOS and Linux: 176 tests passed,
3 excluded, plus native and configured quality checks. The live retest ran on
macOS with a synthetic device, unchanged production buffer settings, and an
isolated in-memory application database.

## Correction

The subsequent [playback recovery change](playback-recovery.md) implements prompt,
bounded channel refill, a 120 ms initial cushion and capacity-capped recovery.
It retains the original evidence here and adds recorded-arrival comparisons and
a new live retest. The section below records the investigation's recommendation.

## Original recommendation

Use these retained timings to evaluate bounded playback buffering and recovery,
including how much cushion survives upstream delivery variation and how long
rebuffering adds after audio returns. Compare inserted silence and added playback
latency before choosing defaults; simply removing refill waits may trade one
gap for repeated gaps. Keep queue limits finite and preserve overflow detection.
Diagnostics should distinguish an empty source queue from confirmed loss during
speech. No playback-policy change is included in this investigation, and a short
physical-speaker check remains necessary to assess perceived audio quality.
