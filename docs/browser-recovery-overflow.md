# Browser recovery overflow — 2026-09-20

## Root cause

The latest browser call exposed an interaction between **the unconditional
200 ms recovery wait added in `2f3f5e9` and a rapid provider audio burst**. Recovery
continues generating silence even when the browser playback queue is full.
That queue backpressures the session pipeline, which stops reading the provider
queue. The burst exhausts the provider's unchanged 700 ms receive capacity.

The relevant branch is `Parlora.Playout.buffering?/3`: for a recovering stream
with `recovery_ms` set, it ignores queued bytes and considers only elapsed time.
The waiting period starts at the first frame after starvation. The previous
queue-threshold condition is bypassed for the full recovery interval.

This is a regression in how the recovery policy handles queue pressure. Faster
pipeline refill is active and working: the trace shows 20 ms reads separated by
roughly 4 ms while the channel has capacity. A fast transfer cannot help once
the downstream queue fills and playout deliberately stops consuming it.

## Actual call evidence

The order correction, item lookup, draft save and automatic save announcement
completed. At **19:05:27 local time**, provider overflow closed the call.
The browser UI retained a 64-entry numeric provider trace; the regular server log
did not retain the browser-call events. A snapshot of the visible page is saved
locally at `/tmp/parlora-browser-playback-20260920-latest.txt`. The repository
fixture retains only the overflow payload and numeric trace, not the transcript.

| Measurement | Observed |
| --- | --- |
| Incoming burst | 11 × 4,800 bytes = 52,800 bytes / 1,100 ms PCM |
| Burst arrival span | 340.258 ms |
| Receive queue before rejected chunk | 31,680 bytes / 660 ms |
| Next chunk | 4,800 bytes / 100 ms |
| Required receive space | 36,480 bytes / 760 ms |
| Receive limit | 33,600 bytes / 700 ms |
| Oldest queued frame | 219.224 ms, below the 750 ms age limit |

The queue is empty at the start of this retained burst. After initial fast reads,
there is a 133.966 ms interval with no provider reads while new chunks continue
arriving. Reads then resume, but cannot recover enough room before the final
chunk. This is capacity exhaustion, not the age deadline or a backend timeout.
`OpenAI.fail_audio/3` explicitly clears retained output, reports failure and closes
the provider; the call closure is that policy operating as implemented.

The trace measures arrival at Parlora's provider boundary. It does not identify
whether the burst originated from upstream generation, network delivery, socket
batching or some combination. The seven starvation counters likewise do not
establish seven audible glitches. Startup capture overflows occurred before
readiness and are separate from this late output failure.

## Reproduction and controlled comparison

Run from the repository with the pinned native toolchain:

```sh
MIX_ENV=test mix run validation/browser-recovery-overflow/replay.exs
```

The probe performs two checks:

1. **Exact retained provider trace:** replays all receives/reads through production
   `Parlora.Provider.OutputBuffer`, verifying every recorded queue and read count. It
   reproduces **31,680 + 4,800 > 33,600** at the rejected chunk.
2. **Recovery comparison:** feeds the same arrivals through production
   `AudioPipeline`, bounded in-memory adapters and `Browser.Media.output/2`
   (including `Playout` and Opus). A deterministic 10 ms browser clock consumes
   output; input receives are quantized to 1 ms. It starts with empty queues and
   recovery active, consistent with the preceding starvation events. Three
   browser clock phases (0, 5 and 9 ms) check sensitivity to timer alignment.

| Recovery policy in the model | First source consumption | Outcome, all three phases |
| --- | --- | --- |
| Current unconditional 200 ms hold | 200–209 ms | Overflow at 341 ms |
| Prior queue-based rule, still a 120 ms cushion | 65–70 ms | All 52,800 bytes consumed; peak provider queue 28,800 bytes |
| No recovery wait (additional control) | 0–9 ms | All 52,800 bytes consumed; peak provider queue 25,920 bytes |

All runs retain the same 33,600-byte provider and 9,600-byte channel bounds and
the same arrivals. The current-policy model's queue at failure is 30,720 bytes;
the exact live trace has 31,680. The model isolates the policy interaction and
does not reconstruct unknown live browser scheduling or queue state byte for
byte. The separate exact-trace check establishes the observed failure precisely.

The probe asserts the failure/control outcomes and capacity bounds. It passes on
both macOS and Linux. Logs and numeric input are under
[validation/browser-recovery-overflow](../validation/browser-recovery-overflow/).
No new live call was required for that diagnosis. The correction and additional
validation below were performed afterward.

## Implemented correction

The output pipeline now uses optional, provider-neutral buffer-status and
channel-recovery callbacks (specified in [public interfaces](public-interfaces.md#output-recovery-pressure)).
When a channel-paced output write is backpressured, it queries the provider's
actual receive occupancy. Recovery releases when provider plus pending pipeline
bytes reach the smaller of half the provider capacity and one channel capacity.
For the current defaults, the threshold is 200 ms upstream of the blocked channel.
The actual device/RTP clock continues to determine playback rate.

A full channel alone is insufficient: an initial experiment releasing at channel
capacity reintroduced the 11,800 ms nonzero gap from the longer jitter fixture.
Waiting until the provider alone reaches half capacity was also too late for the
new burst. The retained implementation accounts for pending frames and the
channel budget; neither failed candidate was accepted by weakening assertions.

This does not add a queue, enlarge a capacity, accelerate speech, or drop samples.
Below the upstream threshold, the bounded recovery wait remains intact. Release
hints are idempotent and epoch-scoped; they cannot affect initial buffering or
cross a clear boundary. Providers/channels that do not implement the optional
callbacks retain their previous behavior. Input and pipeline-paced telephony
output do not use this pressure mechanism.

## Regression results

The exact historical overflow is still reproduced. The controlled comparison now
also exercises the production pressure callbacks in all ten millisecond phases
of the browser clock, through `test/playback_pressure_test.exs` in regular CI.

| Policy, same captured burst and unchanged capacities | Result |
| --- | --- |
| Fixed 200 ms recovery, pressure observation disabled | Overflow in all ten phases |
| Pressure-aware bounded recovery | All 52,800 source bytes consumed in all ten phases |
| First consumption under pressure-aware recovery | 130–139 ms after the first returning chunk |
| Peak provider receive occupancy | 32,640 bytes / 680 ms |
| Peak channel occupancy | 9,600 bytes / 200 ms |

The 20 ms receive headroom at peak is **small**. Passing this trace is not a claim
that extra arbitrary stalls or larger bursts fit these capacities. The documented
700 ms receive capacity, 750 ms receive-age limit, and 500 ms backpressure deadline
still produce explicit failure outside their bounds. Further deployment tuning
must use measured arrival envelopes and latency budgets.

The original and longer jitter replays still meet their previous assertions:
source PCM remains byte-for-byte ordered and complete, the two original nonzero
gaps remain absent, and the longer trial retains only its earlier silent-boundary
gap. Tests also cover unavailable status, low pressure, pipeline-paced output,
provider snapshot immutability, repeated hints, stale epochs, and reset semantics.

## Integration evidence

Evidence is retained in `validation/browser-recovery-overflow/`:

- `macos-fixed-replay.log`, `linux-fixed-replay.log`: deterministic burst comparisons.
- `macos-ci.log`, `linux-ci.log`: full required checks; 184 tests passed and 3 excluded,
  native tests, Credo/ex_slop, ex_dna (zero clones), Credence, and Dialyzer.
- `consumer-macos.log`, `consumer-linux.log`: 107 consumer tests per platform.
- `macos-audio.log`, `linux-audio.log`: actual CPAL/Rubato tone capture, clear/resume
  and cleanup. macOS used built-in speakers/microphone; Linux used a virtual sink.
  Clear calls took approximately 10.4/12.3 ms, respectively. Captured residual
  tone was observed for about 160/80 ms; clear completion does not flush OS audio.
- `macos-soak.log`: two 30-second device cycles; no device errors or capture drops;
  maximum sampled native output queue 2,399 of 4,800 frames.
- `linux-soak.log`: three 60-second virtual-device cycles; no device errors or capture
  drops; maximum sampled native output queue 2,368 of 4,800 frames.
- `live-pcm.log`, `live-summary.json`: a bounded live GPT-Live session through the
  standalone consumer and synthetic CPAL completed the save announcement and
  finalized usage. 115 chunks, zero provider-dropped bytes, peak receive 9,600 bytes.
  One interior 300 ms inserted-silence interval had neighboring sample peaks 1/1.
  The probe closes after observing the confirmation transcript; it does not assert
  that every final audio sample finished playback. No raw microphone audio or
  credentials are retained.

The soaks include clear/resume cycles and report native underruns (macOS 1,440 and
964 frames; Linux 2,048 per cycle). Aggregate counters cannot attribute every
underrun to an intentional clear, scheduling, or audible speech loss. These runs
send directly to the channel, so they verify native bounds/lifecycle rather than
provider-pressure behavior. Sampled process/mailbox peaks remained bounded in
these runs; before/after VM totals include lazy module loading, so they are not a
long-term memory-leak proof.

One Linux CI run while other validation was running timed out in the unrelated
Twilio two-socket test. The four-test file and full CI subsequently passed with
no changes to that test. The first failure is retained in
`linux-ci-first.log` and its isolated recheck in `linux-twilio-recheck.log`;
concurrent load is context, not an established root cause for that failure.

## Production-readiness boundary

This fixes the reproduced recovery/burst interaction and preserves the previous
starvation protections. It does not establish glitch-free operation for arbitrary
networks or production-scale concurrency. Remaining validation includes a fresh
human browser call, controlled impairment of the provider WebSocket and browser
RTP paths separately, longer multi-session load tests with latency percentiles,
and recorded receiver-output comparison under those conditions. Physical Linux
audio remains unverified. Browser handoff, native handoff, transcript observation,
and human hearing remain distinct evidence stages.
