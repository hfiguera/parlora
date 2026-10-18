# Audio release gates

Status: **validation infrastructure, not a production certification**.
See [recorded results and remaining findings](../validation/audio/results-20260921/README.md). Queue
integrity and clean functional calls are necessary but do not prove audibility.
This suite establishes a repeatable baseline and names missing evidence. It does
not increase queue limits to obtain a pass. The deterministic gate task and
browser receiver now exercise the default adaptive policy. Legacy fixed-policy
regressions remain separate. See [the adaptive comparison](../validation/adaptive-playout-20261004/README.md).

The [whole-stream recovery comparison](../validation/playout-policy-20260921/README.md)
adds complete recorded arrivals, policy alternatives and decoded-speech captures.
It rejected immediate recovery as a general replacement: in one recording it
turns one pause into three despite equal total inserted silence. Invariant checks
passing is separate from a policy improving speech continuity and latency.

## Design review

Reviewed September 21, 2026:

- [Pipecat output transport](https://github.com/pipecat-ai/pipecat/blob/main/src/pipecat/transports/base_output.py)
  awaits ordered output frames, chunks audio, and explicitly handles interruption
  and trailing audio. Transfer availability and transport pacing are separate.
- [LiveKit AudioSource](https://docs.livekit.io/reference/python/livekit/rtc/audio_source.html)
  provides queue capacity, awaiting capture, queue clearing and drain waiting.
  Its [Agents output](https://github.com/livekit/agents/blob/main/livekit-agents/livekit/agents/voice/room_io/_output.py)
  uses a 200 ms source queue, additional staging and interruption generations.
  That source queue is not a bound on the entire end-to-end path; those values
  should not simply be copied into Parlora.
- [WebRTC NetEq](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md)
  adapts to arrival history, may stretch audio and conceals lost packets.
  It cannot identify application-generated zero PCM as missing speech. Our
  pre-RTP recovery policy and the receiver's jitter buffer address different stages.

Parlora already has bounded queues, channel pacing, epochs, source-ready hints,
pressure release and cleanup tests. Its recovery policy remains a heuristic.
The tests below evaluate that policy rather than assume it is optimal. They do
not benchmark Pipecat or LiveKit themselves and establish no performance ranking.

## Commands

Use the pinned development toolchain (Elixir 1.20.4 / Erlang 29.1.2). On macOS set
`ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none'` and the documented Rust toolchain.

```sh
# Fast CI subset is also included in mix ci.
mix test test/audio_benchmark_test.exs

# 200 reproducible schedules, spanning all ten 1 ms phases of a 10 ms output tick.
MIX_ENV=test mix parlora.audio_benchmark --seeds 20 --output /tmp/audio-matrix.json

# Requires validation/browser's locked npm dependencies and Playwright Chromium.
# Dedicated loopback listener on 4002; does not alter the example on 4000.
scripts/audio_benchmark.sh /tmp/parlora-audio-gates

# Complete fixed 120/160/200 versus adaptive comparison, all ten render phases.
MIX_ENV=test mix run validation/adaptive-playout-20261004/compare.exs

# Controlled receiver settings for scripts/audio_benchmark_server.exs:
# AUDIO_BUFFERING=adaptive|fixed AUDIO_BUFFER_MS=120 AUDIO_RECOVERY_MS=120
# Identical recorded GPT schedule decoded by Chromium under three policies:
python3 validation/adaptive-playout-20261004/receiver.py /tmp/parlora-adaptive-receiver
```

No model credentials or microphone are used. Generated PCM is a continuous-phase
chirp from 220 Hz upward, at 24 kHz mono signed 16-bit. Its frequency slope is
70 Hz/s for short runs, capped so long runs remain below 3,720 Hz. Receiver WAVs contain only
that generated fixture, captured from Chromium's decoded track before speakers.
The benchmark listener is a local test fixture, not a deployable application.

## Layer 1: deterministic PCM gates

`Scenarios` generates schedules with recorded seeds; `Replay` drives production
`AudioPipeline`, `Parlora.Provider.OutputBuffer`, `AudioQueue` and `Playout`, using a bounded
source fixture and in-memory channel. Source arrivals and playout have a virtual
clock. Production transfer callbacks run, but BEAM scheduling, network timing,
native playback and wall-clock backpressure deadlines are **not simulated claims**.

The normal envelope is deliberately explicit:

| Schedule | Parameters |
| --- | --- |
| Steady | 100 ms chunks every 100 ms |
| Jitter | Ordered 100 ms chunks, each delayed by 0–60 ms |
| Burst | 200 ms chunks every 200 ms |
| Variable | 10/20/50/100 ms chunks, ordered delays of 0–20 ms |
| Transfer stall | One 20 ms transfer stall after one second; playout continues |

Each schedule is three seconds, with a bounded drain. Initial source samples are
available with the first chunk. Passing requires:

- Exact equality of all consumed source PCM: no unexplained drops, duplicates or
  reordering. Inserted silence is counted separately.
- Zero inserted silence **inside** normal continuous source playback.
- First source playback within 150 ms of the first available source chunk. This
  is a proposed local budget: 120 ms startup cushion plus 30 ms transfer/phase margin.
- Provider/channel/pending storage no larger than 33,600/9,600/960 bytes.
- No unexpected errors, and no surviving fixture processes.

Out-of-envelope controls introduce a 250 ms source delay, sustained production
at 1/1.4 of real time, and a 3-second instantaneous burst. The first two may
produce gaps but must preserve every source sample and remain bounded. The burst
must explicitly return `output_overflow`. Finite queues cannot accommodate
arbitrary bursts or make a slow source produce unavailable speech.

A twenty-second cumulative-delay control adds 30 ms every ten 100 ms chunks.
It must retain all source PCM and stay bounded, with at most 600 ms of inserted
silence across the finite run; it does not claim continuity for sustained source
underproduction. The 570 ms cumulative arrival deficit exceeds startup headroom.

A second twenty-second control alternates 500 ms of quiet PCM with 1,500 ms of
nonquiet PCM. Every two seconds of source audio, five 100 ms packet intervals are
extended by 70, 60, 90, 147 and 30 ms. This deliberately exceeds the normal
arrival envelope and exercises repeated shortages with continuous state. Exact
source preservation and queue bounds still apply. Each completed shortage of at
most 80 ms must add no more than 30 ms of recovery wait: enough to transfer the
returning 100 ms packet (20 ms) and reach the next output tick (10 ms).
That is a fixture-specific bound, not a universal speech-gap SLO. Larger shortages
remain separately reported. See the [recorded regression and fix](../validation/browser-gap-20260921/call-1826/README.md).

Reports include starvation counts, startup, source-arrival-to-channel-admission p99, queue peaks,
inserted silence, recovery silence and individual completed gaps (source absence
and added recovery wait). Admission includes intentional queued
backlog: it is not a pure scheduler-latency metric. Fixture mailbox peaks are
harness diagnostics, not a bound on production sessions. Full-session lifecycle,
clear/epoch and historical overflow/jitter regressions remain in `mix ci`.

## Property tests

StreamData 1.4.0 is pinned as a **test-only** dependency. Six properties run as
part of `mix test` / `mix ci`, with 50 generated cases per property by default.
They use ExUnit's seed and shrink failures into smaller input sequences; generated
values are packet specifications and commands rather than enormous PCM binaries.
The three deterministic examples retain minimized findings and the boundary of
the continuity claim. Property modules run synchronously so generated CPU work
does not compete with timing-oriented asynchronous tests in the same suite.

```sh
# Reproduce the same generated cases and test order.
mix test test/*property_test.exs --seed 20260921

# Larger bounded exploration; use a different seed for different sequences.
PARLORA_PROPERTY_RUNS=1000 mix test test/*property_test.exs --seed 20260922
```

`PARLORA_PROPERTY_RUNS` accepts 1–10000. Preserve the failing seed, run count,
generated input and code revision. Promote each useful shrunk counterexample to
a fixed regression. These tests do not use model credentials, real microphones,
network delivery or sleeps to simulate jitter.

| Property | Generated inputs and independent requirement |
| --- | --- |
| Normal arrivals | Ordered packets of 10/20/30/50/70/100 ms, 0–20 ms delay, quiet/nonquiet PCM, 1–239-sample final tails, and all ten 1 ms playback-clock phases. Exact source equality, finite queues, bounded startup/drain, zero internal inserted silence and adapter cleanup. |
| Adverse arrivals | Also allows 200 ms packets and 0–300 ms delay, causing bursts and shortages. Same integrity/bounds/cleanup checks; silence is allowed. This finite generator does not claim arbitrary overload is recoverable. |
| Overload | Random existing queue content plus a packet exceeding remaining capacity. Explicit `output_overflow`, with existing samples unchanged and drainable. |
| Recovery history | Repeated ordinary shortages with 100 ms available on return. Earlier shortages must not delay that ready cushion. Quiet samples count as source audio too. |
| Partial tails | Random 1–239-sample tails, 0–200 ms configured buffers and source shortages up to 600 ms. All source samples must drain within the configured wait without another arrival. |
| Browser control sequences | Writes of 1–480 samples, ticks, clear, stop, resume and stale epochs. A separate ordered-byte model tracks accepted, uncleared audio; production browser callbacks and Media run real Opus encoding against a reference encoder. Queue/staging bounds, stale rejection, suppression, finite final drain and native resource closure are checked. |

The arrival properties use production AudioPipeline, Parlora.Provider.OutputBuffer,
AudioQueue and Playout through the existing virtual-clock replay. They use
10 ms-aligned packet bodies plus a partial final tail; the browser control model
separately exercises arbitrary sample-aligned fragments. The latter compares
pending PCM exactly and encoded packets against an independently maintained
stream. It uses the implementation's source/silence decision to observe timing;
separate timing properties and the bounded final drain check that decision.
It does not test ICE or actual browser rendering.

Mixed 200 ms packets with jitter are deliberately outside the no-gap property.
A first 200 ms packet can satisfy a queue-based startup cushion early, then run
out before a delayed next packet. The ordinary fixed burst case remains tested;
it does not imply every mixture of burst size and delay is gap-free.

Property tests explore combinations; they do not prove universal correctness or
human-perceived audio quality. Keep recorded regressions, decoded browser gates
and listening tests. See [initial findings and validation](../validation/audio-properties-20260921/README.md).

## Layer 2: actual decoded browser output

A separate Bandit test listener uses production Browser and AudioPipeline with
real timers, ICE/DTLS/SRTP, Opus and Chromium. A `MediaStreamTrackProcessor` captures
the decoded remote audio directly, before WebAudio and physical speakers. This
requires the pinned Playwright Chromium; it is not a cross-browser API promise.
No microphone is opened;
a generated silent upstream track supplies the full-duplex negotiation contract.

The runner saves `reference.wav`, `received.wav`, browser statistics, server
observations and gate results per scenario. Normal ten-second chirps must have:

- No internal 1 ms windows below RMS 100 (s16 units), excluding leading/trailing
  idle silence and a 10 ms codec-edge guard measured at 1 ms precision.
  Tail integrity is separately bounded by the duration gate. The reference amplitude is 8,000; this gate is **not for speech**.
- Active duration consistent with the reference and measured receiver acceleration/
  deceleration, with a 40 ms edge allowance. Counter deltas span the warmup-to-end
  observation window, so they bound possible time adjustments rather than assign
  every adjusted sample to active speech. This is a provisional lab budget.
- Decoded signal onset within 300 ms of the test injection request, measured in
  the same browser monotonic clock, at delivery of the first nonquiet decoded
  frame (120 ms initial cushion + 60 ms allowed injection
  jitter + receiver/transfer margin). This is not microphone-to-agent latency.
- Correct frequency progression across the full signal: mean error at most 5 Hz,
  maximum 15 Hz over 100 ms windows after excluding 100 ms at each edge.
- Measured zero additional concealed samples after warmup, no pipeline failure,
  and cleanup to zero benchmark connections.

A rigid sample correlation is reported only as a diagnostic: NetEq can remove or
insert samples to adjust playback timing. Treating a phase shift as packet loss
would give false failures. Acceleration/deceleration counts are retained.
A parallel AudioWorklet capture (`worklet.wav`) and `MediaRecorder` capture
(`received.webm`) are diagnostic sidecars. The former includes another WebAudio
buffering stage; the latter adds another lossy encode. Neither is a speaker
recording. Keeping these independent observations helped identify Worklet-only
gaps under Linux CPU load; they must not be confused with server-inserted silence. The analyzer has negative controls for silence insertion (including
a 5 ms gap hidden inside a 10 ms window), duplicated audio,
clipped tails and a different signal.

The interruption case intentionally suppresses, clears and resumes after 300 ms.
It requires a 200–600 ms measured silent interval, clear acknowledgment within
200 ms, rejection of an old-epoch frame, and resume evidence. The same 10 ms
codec-edge guard applies around the intentional interruption; a second gap outside
that guard fails. Negative controls verify both cases. It is a separate
control check, **not** a pass of the uninterrupted-continuity gates. Disconnect
aborts a running stream; a subsequent fresh connection must pass normal gates.

[WebRTC statistics](https://www.w3.org/TR/webrtc-stats/) describe receiver
concealment and jitter buffering. These are distinct from valid RTP carrying
silence inserted by Parlora. Neither set of counters certifies human perception.

## Release decision

A release report must name the code revision/dirty state, OS, seed range,
scenario duration and capture boundary, and preserve failures. Do not change
thresholds after a failure just to turn a report green. Separate analyzer defects
from actual pipeline defects and retain regression tests for both.

Passing these initial gates covers a defined local operating envelope only.
Before claiming broader production readiness, retain evidence for:

- Long-duration clock drift, CPU/memory pressure and declared concurrent-call capacity.
- Controlled network delay, burst loss and reordering, separately from provider jitter.
- Received **speech** recordings and listening, including interruptions and short tails.
- macOS physical audio and Linux virtual loopback; physical Linux remains unverified.
- Twilio/Telnyx 8 kHz receive-side audio; their successful business workflows do not
  establish PCM/browser audio quality or telephone playback latency.
- End-to-end latency and interruption distributions at p50/p95/p99 for each supported
  environment; explicit SLOs require those baselines, not invented guarantees.

No guarantee covers arbitrary source underproduction, network failure, or device
failure. The release promise should cover integrity, finite resource usage,
measured latency within the declared envelope, explicit degradation outside it,
and prompt cleanup. Benchmark-only additions do not themselves certify a release.

## Speech, load and longer-run controls

`validation/audio/fixtures/speech.wav` is a 13.493-second synthetic reading of
`speech.txt`, generated locally with macOS Samantha and converted to mono 24 kHz
s16 PCM. It contains no caller recording or model output. To capture that fixture:

```sh
python3 - <<'PYCODE'
import wave
with wave.open('validation/audio/fixtures/speech.wav', 'rb') as source:
    open('/tmp/audio-speech.pcm', 'wb').write(source.readframes(source.getnframes()))
PYCODE
AUDIO_REFERENCE_PCM=/tmp/audio-speech.pcm MIX_ENV=test mix run scripts/audio_benchmark_server.exs
# In another terminal:
node validation/audio/receiver.cjs /tmp/audio-speech
```

Do not apply the continuous-chirp analyzer to speech: its natural quiet intervals
are expected. Compare/listen to the reference and received WAVs and retain the
counter evidence separately. Synthetic speech passing transport checks does not
claim semantic or perceptual quality.

For a bounded soak, launch the server and receiver with matching
`AUDIO_SECONDS=180` (maximum 300). The browser sends five-second heartbeats, as
required by the signaling inactivity timeout. `AUDIO_CPU_WORKERS=4` on the Node
runner starts four bounded CPU workers; two runners can exercise concurrent
channels against one listener. These are explicit machine-specific load probes,
not a declared multi-tenant capacity guarantee. Capture buffers intentionally
retain the entire finite test signal; they are not production queue measurements.

A missing Git checkout in an rsync validation mirror is reported as unknown,
not clean. Set `PARLORA_SOURCE_REVISION` to the verified source revision if needed;
source and harness hashes still identify the tested files.
