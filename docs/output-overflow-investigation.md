# Provider output overflow investigation — September 16, 2026

This records the original fix and its measurements. A later acceptance run
exceeded its 500 ms capacity; see the [follow-up investigation and correction](acceptance-overflow-investigation.md)
for the current 700 ms default and the retained regression sequence.

## Finding

At commit `00cfdcc`, the generated-audio receive buffer was too small for observed
delivery bursts. The OpenAI adapter used the same 9,600-byte (200 ms) limit as the
other audio queues. The output pipeline drained at playback speed. Several
provider chunks arriving close together filled the receive queue before the
pipeline could make space; `queue_audio/2` discarded the remainder of the chunk.

This is a receive-buffer/burst-handling limitation in Parlora. It is not evidence
that backend jobs block audio or that CPAL/Rubato cannot keep up. The traced run
had zero output-pipeline backpressure ticks.

## Measured reproduction

A new 300-second macOS physical-audio run used commit `00cfdcc` plus numeric-only
instrumentation. Queue limits and pacing behavior were unchanged. It reproduced
three overflows, dropping 5,760 bytes: **120 ms of generated PCM audio**.
The session finalized with 300 seconds of provider usage.

All 2,913 received chunks were 4,800 bytes: 100 ms each at mono PCM16/24 kHz.
There were 29,993 output-pipeline ticks and 15,500 provider queue reads. The trace
records measurements at the adapter, after base64 decoding; it does not contain
audio, transcripts, credentials, or socket payloads.

The first overflow followed this sequence (times relative to the first chunk
in this burst):

| Time | Operation | Queue afterward |
| --- | --- | ---: |
| 0 ms | Receive 100 ms | 100 ms |
| 0.064 ms | Receive another 100 ms | 200 ms |
| 6.565 ms | Pipeline reads 20 ms | 180 ms |
| 13.924 ms | Receive another 100 ms; only 20 ms fits | 200 ms; **80 ms dropped** |

Before this burst, the receive queue was empty and the pipeline repeatedly
attempted reads. The gap between the preceding chunk and the burst was 291.630 ms.
Three chunks then arrived in 13.924 ms. This directly explains the overflow
without requiring a slow speaker or a delayed backend.

The second burst delivered 300 ms in 62.313 ms. The pipeline removed 80 ms,
leaving 220 ms to fit into 200 ms: **20 ms dropped**. A third overflow dropped
another 20 ms while that backlog remained near capacity. The three overflow
observations were at 92.695, 95.608, and 96.007 seconds relative to the trace's
first observation.

In the 250 ms preceding each overflow, the largest output-pipeline callback
work times were 0.664, 0.376, and 0.586 ms. Maximum tick lateness was below 2 ms
in each window, and no destination reported backpressure. Across the entire
run there were occasional larger delays (maximum tick lateness 37.109 ms), but
those were outside these overflow windows.

Every received/read queue transition was independently reconciled using byte
arithmetic. The calculated losses exactly match the three reported overflows.
[Numeric evidence](output-overflow-evidence.json) retains the surrounding arrival,
read, and tick records and the run totals.

## What this establishes, and what it does not

- The application-level cause is established: a 200 ms receive budget combined
  with paced draining cannot hold the observed bursts.
- The trace does **not** locate the upstream delay: server emission, network/TCP
  delivery, TLS buffering, and local transport dispatch are not separately timed.
  It would be incorrect to claim an OpenAI server defect or a particular network
  fault from these application observations alone.
- This is a new reproduction. The original run retained only overflow counts,
  so its exact lost duration and individual arrival sequences cannot be recovered.
- No audio content was retained. These losses may include silence; their audible
  effect is unknown. The synthetic-caller harness still has its documented limits.

The [official Live WebSocket guide](https://developers.openai.com/api/docs/guides/voice-websockets?api=live#choose-the-audio-format)
requires an ordered PCM stream and allows arbitrary chunk boundaries. It does not
promise that delivery will arrive in evenly spaced chunks matching Parlora's
playback ticks.

## Implemented fix

The provider receive budget is now independent of capture, playback, and uplink:

| Limit | Default | Enforcement |
| --- | ---: | --- |
| `audio_queue_bytes` | 9,600 bytes / 200 ms | Existing capture, playback, and uplink bounds |
| `provider_audio_queue_bytes` | 24,000 bytes / 500 ms | Admit whole generated chunks only when they fit |
| `provider_audio_max_age_ms` | 750 ms | Reject retained audio at or beyond this local residence age on insertion/read |

The observed burst needed 280 ms. The 500 ms receive budget allows that backlog,
another observed 100 ms chunk, and 120 ms of headroom. This is a finite initial
default for measured conditions, not a promise to absorb every network stall.
Playback starts immediately; there is no wait to prefill 500 ms of audio. The
age limit allows residence headroom above the capacity's normal playout duration,
while rejecting stale audio before handing it out. Downstream pipeline, native,
and OS buffering is separate; the age limit is not an end-to-end latency guarantee.

Capacity or age exhaustion emits `:audio_discontinuity` with discarded bytes and
configured limits, clears retained generated audio, and fails/closes the provider
explicitly. The session does not continue after silently dropping part of a spoken
answer. Provider finalization remains unconfirmed on this failure path.

Clear now drains the complete provider receive budget, pending pipeline frames,
and channel buffers. Suppression drains the receive buffer on each poll and once
more at resume; buffered suppressed speech cannot leak into resumed playback.
Remote audio arriving after the local boundary is not retractable by these controls.

Regression tests replay every captured overflow window with synthetic, identifiable
PCM and verify exact byte preservation and ordering. Additional tests cover the
measured 300 ms burst, capacity/age boundaries, explicit provider failure for stale
audio, and clearing/suppression/resume with more than 200 ms buffered.

### Five-minute run after the fix

The traced macOS run completed all 300 configured seconds and closed with finalized
provider usage of 299 seconds. Eight backend requests included seven completions,
one injected failure, one deadline uncertainty, and two stale results. Six result
context appends were acknowledged; all sampled session processes stopped.

| Receive-path measurement | Before fix | After fix |
| --- | ---: | ---: |
| Received 100 ms chunks | 2,913 | 2,913 |
| Provider output overflows | 3 | 0 |
| Generated audio discarded by receive admission | 120 ms | 0 ms |
| Maximum per-chunk receive queue occupancy | 200 ms (saturated) | 240 ms |
| Output-pipeline backpressure ticks | 0 | 0 |
| Receive-age failures | Not implemented | 0 |

The 240 ms peak exceeded the old 200 ms bound while remaining below the new 500 ms
limit. The complete diagnostic trace contained 50,451 numeric records and was not
truncated. [Evidence](output-overflow-evidence.json) includes the final run summary,
trace totals, and the peak-occupancy window. This live run and the deterministic
replays support the specific overflow fix; they do not guarantee lossless audio
through arbitrarily long network stalls.

The run still recorded 13 running device-output underrun observations, including
intentional playback clears. Startup capture overflows and its explicit discard
also remain separately reported. No post-start capture overflows occurred.
Zero provider drops does not establish glitch-free acoustic playback or natural
full-duplex human conversation.

## Reproduce the diagnostics

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin MIX_ENV=test \
python3 scripts/with_keychain.py mix run scripts/trace_output.exs /tmp/parlora-output-new.jsonl
```

Use an unused output filename. This runs the existing five-minute live harness
and requires paid GPT-Live access and the macOS built-in audio devices. Its normal
counters go to stdout; the supplied file contains only numeric timing/queue
records. The collector caps retention at 120,000 events and marks truncation
explicitly. It writes its retained records during cleanup. Exact burst counts
are nondeterministic.

The measurements are exposed through `:telemetry`:

- `[:parlora, :provider, :audio_received]`: chunk bytes, queue before/after, dropped bytes.
- `[:parlora, :provider, :audio_read]`: bytes removed and remaining queue bytes.
- `[:parlora, :audio, :tick]`: callback work, tick lateness, pending frames,
  requested pacing delay, and whether the destination is blocked; metadata identifies direction.

The diagnostic measurements do not themselves alter queue admission or pacing.
After the fix, `mix ci` passed on macOS and Linux with 71 regular tests, native
checks, Credo/ExSlop, ExDNA, Credence, and Dialyzer. The separate three-test stability
suite passed on both platforms. The live run also passed its existing work,
finalization, and process-cleanup assertions. Physical Linux audio remains unverified.
