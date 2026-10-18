# Adaptive PCM playout — October 4, 2026

Browser and LocalAudio now use a bounded receipt-history estimator around
Playout. The default floor is **120 ms**, ceiling **200 ms** (also limited by
channel capacity), and independently configured recovery wait cap **120 ms**.
The implementation preserves every admitted source sample, existing queue
bounds, output clocks, pressure release, clear epochs and short-tail deadlines.
See [the algorithm and configuration](../../docs/playback-recovery.md).

This is qualification of bounded behavior on the development Mac, **not a
production certification or proof of improved perceived speech**. No telephony
playback policy is changed. No new model credentials or source recordings were
needed: decoded receiver runs use a synthetic chirp with recorded arrival timing.

## Complete comparison

[Aggregate results](comparison-summary.json) and [all 1,600 cases](comparison.json.gz)
retain fixed 120/160/200 ms, adaptive, and the previous two-argument fixed
Playout control. Each uses the same production pipeline, source PCM and limits.
Coverage includes nine synthetic schedules × three seeds, three complete
GPT/Gemini/Grok captures and two older recorded regressions, all ten 1 ms phases
of the 10 ms render clock. Synthetic schedules run for 20 seconds of source audio.

Every case passed integrity, capacity, overflow/cleanup and latency gates. For
non-overflow streams, all source bytes match exactly before Opus, including
quiet PCM and partial tails. Startup is bounded by the selected target plus one
render tick; recovery holds remain within 120 ms plus one tick. Complete-stream
inserted silence cannot exceed the unavoidable receipt deficit after actual
startup by more than that recovery allowance. The older fixed-policy ordinary
shortage oracle remains unchanged; adaptive recovery explicitly permits learned
headroom within its separate recovery bound.

Worst results over all phases:

| Capture | Policy | Local gaps | Longest gap | Total inserted silence | Startup |
| --- | --- | ---: | ---: | ---: | ---: |
| GPT Live | fixed 120/160/200 | 14 | 70 ms | 410 ms | 113 ms |
| GPT Live | adaptive | 9 | 110 ms | 430 ms | 113 ms |
| Gemini | fixed 120 / adaptive | 1 | 20 ms | 29.958 ms | 19 ms |
| Gemini | fixed 160 | 0 | 0 | 0 | 169 ms |
| Gemini | fixed 200 | 0 | 0 | 0 | 209 ms |
| Grok | all policies | 0 | 0 | 0 | 9 ms |

Worst maxima need not come from the same phase. The GPT capture starts with
enough queued PCM that simply raising the fixed target does not delay startup
or add useful reserve. The [startup-only experiment](startup-only-summary.json)
also found no improvement from learning without recovery headroom; only its
aggregate results are retained. The final implementation uses learned headroom
at recovery boundaries too. In repeated synthetic shortages it reduces worst
gap count from 49 to 32, while longest gap grows from 190 to 220 ms and total
inserted silence grows from 3,870 to 3,940 ms. Source underproduction cannot be
fixed by a bounded jitter buffer: the underproduction fixture still inserts
7,840 ms, with fewer, longer pauses.

These are tradeoffs, not a claim that adaptive wins every metric. A 200 ms
ceiling cannot cover arbitrary 360–500 ms source stalls. Repeated small gaps
versus fewer longer pauses must also be compared with real spoken audio.

## Decoded browser receiver

[Receiver results](receiver-results.json) and [numeric timing](receiver-timing.json)
compare three runs on the same complete 43.8-second GPT receipt schedule,
with no artificial CPU workers. Every run packetized all 2,102,400 source bytes,
drained its tail, cleaned up, and reported zero steady receiver concealment and
zero packet loss. The actual local scheduling differs from the virtual model.

| Policy | Local gap count | Local inserted silence | Decoded silence | Longest decoded gap | Decoded startup |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixed 120 | 14 | 390 ms | 115 ms | 46 ms | 138.8 ms |
| fixed 200 | 13 | 380 ms | 123 ms | 45 ms | 143.7 ms |
| adaptive | 7 | 420 ms | 264 ms | 85 ms | 133.0 ms |

Decoded gaps use the analyzer's RMS threshold. Opus/NetEq decay and comfort
noise can mask locally inserted silence, so that measure is not a sample-exact
source accounting or an audibility judgment. Adaptive reduces local gap count,
but decoded silence and longest decoded pause increase. Listening validation
is still required. Largest observed server playout intervals were 19.732,
21.241 and 19.914 ms respectively; no cause is assigned from separate clocks.

The [adaptive audio gates](audio-gates.json) additionally passed 200 deterministic
schedules and seven Chromium cases: steady, jitter, burst, variable, interruption,
disconnect and reconnect. Their source hashes capture the code at execution;
a subsequent diagnostics-only correction reports the startup deadline after long
idle, separately covered by the final tests.

The final [120-second jitter soak with two CPU workers](cpu-soak.json) also
passed, packetizing all **5,760,000 source bytes** with no interior decoded
silence, no steady concealment, no packet loss and a fully drained output queue.
[Its timing trace](cpu-soak-timing.json) is complete: largest observed server
playout interval **11.620 ms**, with no intervals over 15 ms. This controlled
arrival envelope stays below the 120 ms floor; the recorded GPT run above
separately exercises target increases and decreases.

## Verification and reproduction

Final checks and source hashes are recorded in [verification](verification.json).
The root suite includes estimator grouping, negative clock origins, clock/stream
resets, unknown clocks, idle exclusion, bounded history, slow shrink across short
replies, target latching, independent recovery deadlines, capacity/pressure,
suppression and stale admission tests. Existing byte-integrity and clear-epoch
properties remain enabled. The historical observed-recovery negative control
still fails its per-gap gate at all ten phases; it is retained as a control.

The final CI also exposed an unrelated asynchronous test assumption: waiting for
output progress did not guarantee input progress was already visible. That test
now waits for both counters and the caption observation before asserting them.
Runtime session health behavior is unchanged.

```sh
MIX_ENV=test mix run validation/adaptive-playout-20261004/compare.exs
python3 validation/adaptive-playout-20261004/receiver.py /tmp/parlora-adaptive-receiver
scripts/audio_benchmark.sh /tmp/parlora-adaptive-audio-gates
mix ci
PARLORA_BACKEND=sagents scripts/consumer.sh /absolute/path/to/new/consumer
```

Decompress the complete virtual report with `gzip -dc comparison.json.gz`.
Raw receiver WAVs, server traces and logs remain under `/tmp` rather than in the
source package. Linux execution, physical speakers, live provider listening,
WAN fault injection and fleet/long-call SLOs remain outside this qualification.
The earlier [isolated receiver concealment failure](../playout-hardening-20261003/README.md)
remains retained; these passing runs do not establish its root cause.
