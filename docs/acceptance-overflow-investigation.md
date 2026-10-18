# Acceptance call overflow: root cause

## Finding

The sixth live acceptance call exceeded Parlora's **500 ms provider receive
capacity while its output pipeline was draining normally at playback speed**.
Six 100 ms PCM chunks arrived at the adapter within 79.201 ms. The pipeline
removed 80 ms, leaving 520 ms to accommodate. The last whole-chunk insertion
therefore failed: **20,160 queued + 4,800 incoming > 24,000 bytes**.

This is a larger instance of the receive-burst limitation documented in the
[earlier investigation](output-overflow-investigation.md). That fix separated
the provider receive budget from the 200 ms playback budget and increased it to
500 ms based on the bursts measured then. It did not establish a maximum burst
size for future calls. The retained older regression windows cannot catch this
new 520 ms backlog.

The call closed because Parlora deliberately treats receive-capacity exhaustion
as fatal. It did not close because the user pressed Disconnect, because the
backend failed, or because interpretation asked for clarification.

## Exact retained sequence

Source: [original case evidence](../validation/acceptance/results/6-interrupt-disconnect.json),
the provider `audio_discontinuity` payload's `audio_trace`.
PCM is 24 kHz, mono, signed 16-bit: 48 bytes per millisecond.
Times below are relative to the first chunk of this burst.

| Time (ms) | Operation | Required queue afterward (ms) |
| ---: | --- | ---: |
| 0.000 | Receive 100 ms | 100 |
| 0.920 | Receive 100 ms | 200 |
| 3.041 | Read 20 ms | 180 |
| 22.943 | Read 20 ms | 160 |
| 38.808 | Receive 100 ms | 260 |
| 39.790 | Receive 100 ms | 360 |
| 43.024 | Read 20 ms | 340 |
| 62.012 | Read 20 ms | 320 |
| 76.156 | Receive 100 ms | 420 |
| 79.201 | Receive 100 ms | **520: rejected** |

The retained trace begins with an empty queue and contains 54 empty reads before
the burst. It is truncated only before that known empty starting state, so the
complete buildup responsible for this overflow is available. The four reads
during the burst are separated by 19.902, 20.081, and 18.988 ms. There is no
missing drain interval here that would explain the overflow as stalled playback.
Even an ideal continuously paced drain would leave about 521 ms after 79 ms;
the measured drain is already slightly ahead of that calculation.

The oldest retained frame was only 79.203 ms old when the failure was emitted.
The separate 750 ms residence-age deadline was not reached. Increasing that
deadline would not address this capacity failure.

## Code path

- `AudioPipeline.refill/1` reads up to `max_frame_bytes` (960 bytes / 20 ms).
  `forward/1` hands off each 480-byte / 10 ms frame, pacing by frame duration.
  It does not empty a burst into the destination immediately.
- `OpenAI.queue_audio/2` passes each received PCM chunk to `OutputBuffer.push/5`.
  The buffer rejects the entire incoming chunk if the total exceeds capacity.
- `OpenAI.fail_audio/3` emits the retained diagnostic, clears the 20,160 buffered
  bytes, and invokes `fail/2`. The rejected chunk brings discarded audio to
  24,960 bytes / 520 ms.
- `fail/2` emits `:failed`; `finish/2` closes the HTTP connection and emits
  `:closed`. The session handles adapter failure by starting cleanup.

At diagnosis, the standalone consumer's vendored `OutputBuffer` and `AudioPipeline`
matched this repository's implementations. The captured 24,000-byte capacity also
confirms that this run used the newer receive budget, not the old 9,600-byte bound.

## Offline reproduction

From the repository root, with the pinned development toolchain:

```sh
mix run --no-start validation/acceptance/replay_overflow.exs
```

The diagnostic replays every retained read/arrival against the production
`OutputBuffer` with the recorded 24,000-byte limit, synthetic PCM, and recorded
timestamps. It checks every queue transition, all read sizes, and the exact final failure. It reproduced the
overflow on Elixir 1.20.4 / OTP 29.0.6 without a browser, backend, network call,
credentials, or physical audio. Exit success means the recorded failure was
reproduced; it does not mean it was fixed.

## Limits of the conclusion and follow-up

The application-level cause is established. The trace timestamps are recorded
after WebSocket decoding; they cannot distinguish server output batching,
network/TLS buffering, or local transport dispatch. It does not establish that
the spoken interruption caused the burst, nor that any particular upstream
component is defective. No raw audio was retained, so the discarded portion
cannot be classified as speech or silence.

The interruption case stopped before its intended disconnect/reconnect. The
absence of a corrected order-124 job is not evidence of another policy failure;
the connection was terminated before that scenario could finish.

The correction must retain ordered PCM, finite memory, and explicit latency
limits. Faster playback is not a solution. A larger budget can absorb this
specific burst but is not by itself a guarantee against future bursts. The
sequence is retained as regression evidence. No runtime behavior or bounds
changed during diagnosis; the subsequent correction is described below.

## Implemented correction

The default receive capacity is now **33,600 bytes / 700 ms**. This admits the
captured 520 ms backlog with 180 ms of capacity headroom. The separate **750 ms
local residence deadline remains unchanged**, leaving 50 ms of nominal drain
headroom at a full receive queue. There is no new prefill wait or faster playback.
Capture, channel playback, and provider uplink bounds remain 200 ms.

This is a measured capacity correction, not an adaptive jitter buffer or a new
loss-recovery protocol. Closing explicitly on capacity/age exhaustion remains the
policy: silently discarding part of an answer or replaying stale speech would
misrepresent delivery. Larger upstream bursts can still exceed the finite budget.
Applications can configure these limits, with the documented memory and latency
tradeoffs. The residence deadline covers the provider queue, not downstream device
or browser latency.

`test/acceptance_burst_test.exs` replays the actual arrival/read sequence with
identifiable synthetic PCM. The recorded 500 ms limit fails; the new default
admits it, then drains every byte in order at the recorded 20 ms read cadence
without reaching the age deadline. Boundary tests continue to reject capacity
exhaustion and stale frames. Clear/suppression/resume tests now fill the entire
700 ms budget, ensuring those controls leave no retained tail.

### Verification after the correction

`mix ci` passed on macOS and Linux (114 tests, three tagged exclusions, all native
and quality checks). The consumer's 51 tests passed on both systems.

The live interruption/disconnect case passed on the first run after the fix,
including reconnection and persistence checks previously blocked by closure.
No provider overflow or other provider audio discontinuity was recorded across
the six live cases. The complete suite still returned failure: the first case's
“one-twenty three” was left unresolved and prompted clarification. That separate
interpretation finding is preserved, not counted as an audio pass or retried away.
See [full results and retained evidence](../validation/acceptance/RESULTS.md#after-the-receive-capacity-correction).
