# Stability validation — September 16, 2026

## Scope and acceptance

These are bounded tests of the current local-audio implementation, not a claim of
unlimited call duration or production capacity. The current toolchain is Elixir
1.20.4-otp-29, Erlang 29.1.2, and Rust 1.92.0, with committed dependency locks.
The original measurements below used Erlang 29.0.6; see the
[29.1.2 regression checks](../validation/otp-2912-20261017/README.md) for the upgrade.

Three complementary harnesses are available:

| Harness | Workload | Required evidence |
| --- | --- | --- |
| `test/stability_test.exs` | 100 session lifecycles, four simultaneous revisions each, seeded completion order, duplicate results, failure/cancellation/provider loss; another session with 500 completed revisions | No stale/duplicate context injection; bounded queues/jobs; all sampled owned processes stop; post-warmup BEAM growth under 16 MB and process-count growth at most five; explicit deadline and exhaustion outcomes |
| `scripts/stability_audio.exs` | Three 60-second CPAL/Rubato cycles, one-second warmup per cycle, clear/resume every 15 seconds, close/reopen between cycles | Native queues within 4,800 frames, zero device errors and post-warmup capture drops, callback handoff advances, clear epoch acknowledged, bounded close |
| `scripts/stability_live.exs` | Five-minute GPT-Live connection with physical macOS audio, synthesized caller phrases, pauses, corrections, and a controlled fake backend | At least two backend requests and an acknowledged result; finalized close; session process cleanup; bounded adapter queues; timings and memory samples |

Run commands and environment controls are in [README](../README.md#stability-validation).
The simulation suite is an explicit CI step after `mix ci`; paid/live and hardware
runs remain separate. Machine-readable summaries are in
[stability-results.json](stability-results.json). No raw audio, transcript contents,
credentials, or adapter-state dumps are retained in those summaries.

## Simulated sessions

The internal completion-order seed is `{42, 17, 91}`; ExUnit also runs with seed 42.
Code loading must settle for three consecutive warmup batches, with a maximum of
80 warmup sessions. Reporting and every fault mode are exercised before measuring.
The 16 MB growth allowance is unchanged; cold code loading is recorded separately.

| Measurement | macOS | Linux |
| --- | ---: | ---: |
| Warmup sessions before code settled | 28 | 40 |
| Measured session cycles | 100 | 100 |
| BEAM memory, baseline → final | 138,748,362 → 138,801,010 bytes | 125,977,176 → 126,018,168 bytes |
| Process count, baseline → final | 172 → 172 | 172 → 172 |
| Largest sampled audio queue | 480 bytes | 480 bytes |
| Largest observed four-request admission time | 6.757 ms | 3.336 ms |
| Largest cleanup time | 7.169 ms | 7.038 ms |
| Sampled session processes surviving cleanup | 0 | 0 |

The separate 500-revision session intentionally retains job/transcript history.
Sampled owned-process memory grew from about 60 KB to 4.13 MB on macOS, and 80 KB to 4.82 MB
on Linux, then the processes were removed at close. Maximum observed request
admission was 4.393 ms and 17.191 ms respectively. History is bounded by configured
record/transcript caps; it is not constant-memory within one long session. The
suite also verifies controlled closure when a reduced transcript cap is reached.

RSS decreased during the repeated-session run on both machines. RSS includes VM
allocators and native memory; neither falling RSS nor these short runs proves the
absence of every possible leak. Measurements are samples, not continuous peaks.

## Continuous native audio

macOS used the built-in microphone/speakers at 48 kHz through CoreAudio. Linux used
a temporary 48 kHz stereo PulseAudio/PipeWire null sink and its monitor. Each run
covered 180 measured seconds plus warmup and startup/close overhead.

| Measurement | macOS physical | Linux virtual |
| --- | ---: | ---: |
| Post-warmup capture drops / device errors | 0 / 0 | 0 / 0 |
| Largest sampled native input queue | 480 frames | 480 frames |
| Largest sampled native output queue | 2,399 frames | 2,218 frames |
| Maximum observed poll gap | 17.143 ms | 14.230 ms |
| Clear acknowledgment range | 2.684–9.272 ms | 1.334–11.457 ms |
| Close range | 56.885–63.858 ms | 10.777–13.113 ms |
| Underrun frames per cycle, including deliberate clears | 1,920–1,924 | 2,048 |

Underrun totals include the four intentional clears in each cycle and are not a
count of unexpected audible glitches. This harness verifies handoff and epoch
adoption, not acoustic recognition of the tone or proof of human hearing. Earlier
short tone-recovery measurements remain in [implementation status](implementation-status.md).
Physical Linux audio remains unverified.

## Initial five-minute live run

The session finalized with 300.0 seconds of provider usage. Observed work included:

- Seven admitted/started backend requests; six completions and one injected failure.
- A 35-second backend operation exceeded the 30-second deadline, producing an
  explicit uncertain outcome before its later completion.
- Two obsolete results were discarded; five result appends were acknowledged.
- A clarification request and six delegation associations were observed.
- Completion-to-context-acknowledgment timings: 690–730 ms. This is not speech or
  acoustic playback latency.
- Peak sampled adapter queue occupancy: 9,600 bytes, at the configured limit.
- Sampled persistent session-process memory peaked at 729,040 bytes; mailbox
  sampling peaked at one message. Sampling after event consumption can miss bursts.
- BEAM memory was approximately 143.9–144.6 MB during the run. RSS was approximately
  194.8–198.2 MB. Small retained-history growth is expected within a running session.

The harness recorded 188 audio-discontinuity events. The first run counted event
kinds without separating discontinuity causes, so it is not evidence of glitch-free
live audio. A 45-second follow-up diagnostic observed 56 channel capture-overflow events and
four device-output underrun events. Its capture queue stayed near 180 ms: buffered
pre-ready audio was retained when the provider became ready. This motivated the
startup-buffer change below and a second five-minute run with phase-specific
discontinuity counters. Audio handoff is session-wide, may include silence, and
is not attributed to a particular result.

The largest sampling interval was 2.972 seconds, including initial measurement
work; this is not a measured device/audio scheduling stall. CPU checks overlapped
some validation runs, so these figures describe this development environment,
not an isolated performance benchmark.

Caller speech was synthesized through speakers and captured through the microphone.
The harness explicitly suppresses/clears model output while the caller speaks and
mutes input between caller phrases to prevent feedback. This tests the integrated
path with varied phrases and pauses, but not free-form human conversation, natural
barge-in, or acoustic echo cancellation. The backend is fake; production Jido
integration remains covered by the existing adapter/substitution tests.

## Five-minute repeat after the startup fix

The repeat finalized successfully with 299.0 seconds of reported provider usage
over the configured 300-second exercise. All sampled session processes stopped.

| Measurement | Result |
| --- | ---: |
| Backend requests / completed / failed | 8 / 7 / 1 |
| Deadline uncertainty / stale results | 1 / 2 |
| Result context acknowledgments | 6 |
| Completion → context acknowledgment | 615–1,184 ms |
| Largest sampled capture queue | 2,400 bytes (50 ms) |
| Largest sampled playback / generated-output / uplink queue | 960 / 8,640 / 960 bytes |
| Sampled session-process memory peak / mailbox peak | 714,312 bytes / 1 message |
| Sampled BEAM memory range | 142.0–144.0 MB |
| Sampled RSS range | 193.8–197.4 MB |

Capture samples were generally 10–30 ms before rising to 50 ms near the end,
compared with roughly 180–200 ms before the fix. The discontinuity counters recorded:

- Startup: 129 channel capture overflows, one device-output underrun, and one
  explicit startup-buffer discard.
- Running: zero capture overflows, 14 device-output underruns, and three provider
  output overflows.

The startup/running boundary is sampled immediately after readiness and initial
control/context setup. Startup counts include microphone capture while the network
session connects; callers should wait for the greeting before speaking. The fix
discards accumulated input instead of forwarding that backlog into the conversation.

The remaining provider output overflows represent discarded generated audio when
the bounded queue fills. The counters establish their occurrence, but do not yet
identify the cause or dropped duration. Device-output underruns include deliberate
playback clearing; this harness cannot classify each as an audible glitch. These
remain audio-quality findings for follow-up, despite successful result delivery,
bounded queues, and cleanup. Queue capacities were not enlarged to hide them.

A subsequent [overflow investigation and fix](output-overflow-investigation.md) reproduced
the output loss and identified delivery bursts exceeding the 200 ms receive budget:
300 ms arrived in 13.924 ms while playback was draining normally. The new run lost
120 ms across three overflows. It establishes the buffering limitation without
identifying where upstream delivery was delayed or whether the lost audio was audible.
The provider receive buffer now has its own finite capacity and age limit; replay
tests preserve all audio in those captured windows. The linked report records the
follow-up validation separately from these original measurements.

Both platforms passed `mix ci` (65 regular tests; three stability tests excluded)
and the separate three-test stability suite. Credo, ex_slop, ex_dna, Credence, and
Dialyzer checks passed. The two native-audio runs also passed their assertions.
The live run passed its work, queue-capacity, finalization, and cleanup assertions;
it does not assert zero discontinuities or establish glitch-free speech.

## Findings and changes

1. **Unfinished jobs at close:** the connection-loss test exposed final `:submitted`
   statuses after session shutdown. Final outcomes now report these as `:uncertain`.
   Cleanup cannot establish whether external work completed or was cancelled.
2. **Cold-start memory:** early baselines included later code loading, producing
   false growth failures. Bounded warmup now waits for code size to stabilize;
   the process and memory assertions were retained unchanged.
3. **Pre-ready capture backlog:** the input pipeline now discards its bounded
   startup capture buffer explicitly, reporting `:startup_buffer_discard` with
   frame count and duration. A regression test proves fresh input is forwarded
   afterward. This changes startup handling, not queue capacity or output playback.
4. **Longer manual sessions:** `PARLORA_DEMO_SECONDS` makes the local example's
   duration configurable (default 120, maximum 1,800 seconds). Existing runtime
   limits remain enforced; longer duration does not imply unlimited retained state.

## Remaining limits

- Physical Linux audio, free-form long human conversations, and actual network
  transport interruption are not established by these runs. Provider loss is
  injected through the normalized adapter event in the deterministic suite.
- Live ASR and delegation timing remain nondeterministic. A short API connection
  or a successful live result alone does not satisfy the simulation assertions.
- The subsequent provider receive-buffer adjustment is based on measured bursts;
  capture/playback bounds remain unchanged. Do not enlarge unrelated queues to
  hide discontinuities or turn finite-history exhaustion into unbounded retention.

## Subsequent browser concurrency validation

The [concurrent browser-session pilot](../validation/concurrency/README.md) passed
1/2/4-call cohorts on macOS and Linux using real WebRTC/Opus and a shared Jido
application, plus stalled/killed-provider containment and the unchanged four-call
OrderDesk admission gate. Two simultaneous synthetic live-provider calls also
passed. Its report records tone-detector bounds, timing/resource measurements,
source provenance, and qualification failures separately from the earlier results
above. This adds short browser concurrency coverage, not a production capacity
limit or human-conversation validation.
