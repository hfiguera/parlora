# First-version implementation and validation

October 17, 2026 boundary hardening: bounded context-policy failure recovery and
request-isolated Jido result validation. See the
[regression cases and packaged-consumer checks](../validation/boundary-hardening-20261017/README.md).

October 17, 2026 compatibility update: supported consumer runtimes start at
Elixir **1.18** / OTP **27**, with CI pairs **1.18/27, 1.19/28 and 1.20/29**.
Development pins remain unchanged. See the [compatibility policy](beam-compatibility.md)
and [local matrix checks](../validation/beam-compatibility-20261017/README.md).

October 17, 2026 toolchain update: development and the CI quality lane use Erlang/OTP **29.1.2**
with Elixir **1.20.4-otp-29** and Rust **1.92.0**. See the
[upgrade regression checks](../validation/otp-2912-20261017/README.md).
Older measurements below retain the toolchain used for those runs.

October 17, 2026 dependency update: Bandit 1.13.1, Jido 2.4.0, Sagents 0.17.1
and Legion 0.6.0. See the [source impact review and checks](../validation/dependency-upgrade-20261017/README.md).

October 3, 2026 extension: optional Sagents 0.16.0 joins Jido as a selectable
OrderDesk backend. The [backend guide](sagents-backend.md) describes supported
capabilities, model configuration and validation; the original milestone evidence
below retains its original scope and dates.

Validation date: September 15, 2026. The first-version implementation covers
Milestones 1–3: LocalAudio, GPT-Live-1 client delegation, Jido, the public adapter
contracts, application-owned context interpretation, and in-memory sessions.
At that initial milestone, browser/telephony adapters and libopus bridging were
deferred. The subsequent [browser milestone](browser-channel.md) adds browser
WebRTC and libopus; telephony, other built-in providers/backends, and durable
restoration remain deferred.

## Acceptance evidence

| Brief scenario | Supporting evidence |
| --- | --- |
| 1. Audio ownership | `AudioPipeline` routes both directions; physical CPAL/Rubato tone recovery and the acoustic live order test exercise capture and playback. |
| 2. Concurrent conversation | Session and substitution tests exchange audio while jobs remain pending; the live model speaks while Jido's deliberately slow lookup runs. |
| 3. Correction during work | Deterministic tests and live order 123 → 124 run; current result enters context, model transcript says “out for delivery,” and subsequent CPAL handoff is observed. |
| 4. Partial context | Early delegation waits until transcript context supplies an order; clarification remains pending and is deduplicated. |
| 5. Duplicate delivery | Repeated delegation, terminal result, cancellation ID, and clear ID do not repeat effects. Conflicting IDs and record exhaustion fail explicitly. |
| 6. Cancellation race | Superseded and uncertain jobs retain occupancy. Late results are recorded as stale. Queued cancellation proves only that this request was never submitted; running cancellation needs an explicit backend terminal outcome. |
| 7. Playback clearing | Native playback epochs, callback acknowledgment, Rubato reset, stale-frame rejection, suppression/resume tests, and physical/virtual tail measurements below. |
| 8. Slow consumers | Byte-limited queues, native ring overflow counters, job/delegation bounds, and a 500 ms sustained audio-backpressure deadline. A stalled pipeline closes its session. |
| 9. Failure/replacement | Adapter/pipeline death closes owned resources; startup failures clean partial ownership. A fresh session starts no prior work automatically. |
| 10. Graceful close | Final usage or explicit incomplete finalization; repeated native close and owner death; policy workers are supervised inside their session and Jido workers inside their adapter. |
| 11. Substitution | The same correction/audio test runs all four combinations of MemoryChannel/LocalAudio and FakeBackend/Jido. LocalAudio uses its native synthetic callback harness in deterministic tests. |
| 12. Readiness/configuration | Delayed readiness and incompatible capabilities tests; startup/history validation; real `session.started` handshake and silent-input greeting. |
| 13. Transcript fidelity | Exact spaces, repetition, overlapping intervals, and late deltas retained; snapshot revision rejects stale policy decisions. A forced completion/correction race verifies that results wait for interpretation before becoming speakable. |
| 14. Context delivery | Correlated append/error protocol tests, simulated rejection without retry, current task/delegation checks, and an oversized live append rejected by GPT-Live. No approximate token counter is used. |
| 15. Independent controls | Mute, suppression, clearing, and backend cancellation are separate; capture continues while playback is suppressed. Silent input produces a live greeting. |
| 16. Usage/fresh context | Cumulative usage snapshots replace earlier values; missing finalization remains unconfirmed. History/context seed fresh runtime state without replay. |

Tests are in `test/`; reusable simulated adapters are in `test/support/`.
The original `validation/` fixtures retain their own narrower results and limits.
They are references, not substitutes for the integrated evidence here.

## Platform and audio measurements

Toolchain: Elixir **1.20.4-otp-29**, Erlang **29.0.6**, Rust **1.92.0**.
Native dependencies: Rustler **0.38.0**, CPAL **0.18.2**, Rubato **5.0.0**.
Measurements use 15 seconds of 440 Hz PCM tone before and after a clear, with
half-second silent phases; generated amplitude is 1,000 PCM16 units. Captured
PCM stays in memory. Twenty-millisecond windows estimate tone strength and tail.

| Observation | macOS arm64, built-in mic/speakers | Linux x86_64, PulseAudio/PipeWire null sink/monitor |
| --- | --- | --- |
| Native format | 48 kHz f32, mono input/stereo output | 48 kHz f32, stereo input/output |
| Capture drops after warmup / during startup | 0 / 960 | 0 / 0 |
| Device errors | 0 | 0 |
| Maximum device poll gap | 22.548 ms | 14.983 ms |
| Clear command | 1.775 ms | 1.219 ms |
| Close through closed event | 28.952 ms | 8.721 ms |
| Native frames queued before clear | 1,458 (30.4 ms) | 1,570 (32.7 ms) |
| Approximate captured tail after clear | 140 ms | 60 ms |
| Tone amplitude before / after resume | 570.0 / 588.7 | 993.0 / 992.8 |
| Tone amplitude after first 200 ms of clear | 6.8 (room noise) | 0 |
| Final resampling adjustment, input/output | −16 / +16 ppm | −13 / +60 ppm |

The Mac run used `+sbwt none +sbwtdcpu none +sbwtdio none`. Without those flags,
idle development runs intermittently delayed even an isolated 5 ms BEAM timer
by approximately one second and dropped capture frames. A paired timer check
measured maximum gaps of 863.6 ms with default settings and 9.3 ms with busy
waiting disabled. A temporary user-activity assertion also avoided the stalls,
but is unnecessary with the measured flags. This points to an interaction with
host scheduling/power state; it is not proof of a particular OTP or macOS bug.
The local launcher applies the measured flags when `ERL_FLAGS` is unset.
No persistent OS power settings are changed. Early failed runs remain relevant:
finite queues report dropouts, and this library does not provide hard realtime
scheduling guarantees under arbitrary host load.

A repeated Mac run with cold native initialization dropped 960 capture frames
(20 ms) before warmup, while conversion resources were being created. The earlier
warm run had zero startup drops. No additional capture drops occurred during the
31-second measured path. Preready capture is bounded and may be discarded.

Native output underruns include startup and the intentional empty queue after
clearing: the Mac count increased by 480 frames (10 ms) after warmup. OS/device
buffering and room acoustics remain outside clear's guarantee. `rendered` includes
silence; `handed_off` counts queue consumption by the callback. Neither establishes
human hearing. CPAL supplies no acoustic echo cancellation; use headphones for
ordinary microphone conversations. **Physical Linux audio is unverified.** These
short runs exercise drift adjustment but do not establish long-call capacity or
stability on other devices.

### Reproduction

On the development Mac:

```sh
export RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin
export ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none'
CPAL_HOST=CoreAudio CPAL_INPUT='MacBook Pro Microphone' \
  CPAL_OUTPUT='MacBook Pro Speakers' CPAL_TONE_BLOCKS=1500 \
  mix run scripts/audio_validation.exs
python3 scripts/with_keychain.py mix run scripts/live_smoke.exs
python3 scripts/with_keychain.py mix run scripts/live_order_validation.exs
```

On Linux, activate the same pinned BEAM/Rust toolchain and native development
headers, then run `CPAL_TONE_BLOCKS=1500 scripts/linux_audio.sh`. It creates and
removes its own temporary sink without changing default devices. The checks ran
via `ssh linux` in `/tmp/parlora-v1-20260915`, using the pre-existing toolchain and
header prefix `/tmp/parlora-media-compat.M98wEs`.

## Live GPT-Live evidence

The bounded provider smoke run became ready, generated 321,600 audio bytes during
paced silence, acknowledged the greeting instruction, rejected the oversized
append, and finalized with `close_requested` and 7.0 seconds of final usage.
The command ID is retained by the adapter; rejection does not trigger a retry.

The integrated acoustic run used `/usr/bin/say` through laptop speakers into the
physical microphone, with actual LocalAudio → OpenAI → Jido processing. It
admitted order 123/revision 1 and then 124/revision 2, discarded the old answer,
returned the current result, observed “out for delivery” in generated speech
text, and observed subsequent callback handoff. It moved 1,572,000 output bytes,
received two delegations, reported no policy errors, and finalized. The first
useful result transcript arrived 14.503 seconds after the test caller started;
a subsequent callback handoff was observed at 14.510 seconds. This includes
scripted caller speech and a deliberate backend delay. An earlier successful run
observed the useful transcript at 15.976 seconds. These are not acoustic playback
timestamps or provider latency benchmarks.

For this loudspeaker-loop test, output is suppressed and cleared while synthetic
caller speech plays, then resumed. Earlier overlapping synthetic utterances did
not capture a reliable correction; serializing them fixed that overlap. One later
replay did not produce a recognized order and correctly started no backend work.
The demo now has tests for common spoken-number and punctuation variants, including
digit-by-digit captions such as `order ,1, 2, 4`. A user run exposed that separated
digits previously matched no order, leaving the delegation pending without submitting
a lookup. A regression test replays those caption fragments through a session using
the example policy, verifies the correction from 123 to 124, discards the old result,
and delivers the current result as speakable context. This replay uses an in-memory
provider and fake backend; it does not establish a new physical/live audio result.
The example is deliberately a bounded catalog parser, not general language understanding.
The loudspeaker-loop test's output control is not automatic barge-in or echo cancellation
in the library. Separate
physical tone recovery establishes the output/capture path; a transcript alone
is not treated as playback evidence. No test claims that a human heard a phrase.

Credentials are obtained from the authorized Keychain item only in the launcher,
passed through runtime configuration and explicit `api_key:`, and never printed,
written to files, or included in context/events/default telemetry.

## Build, checks, and packaging

The later [stability validation](stability-validation.md) adds 100 repeated-session
cycles, a 500-revision session, three-minute native audio runs on each platform,
and bounded live testing. It also fixes final uncertainty reporting and discards
pre-ready capture explicitly when the input pipeline starts. The current fast
suite has 74 tests; three additional stability tests run as a separate CI step.
The [output overflow fix](output-overflow-investigation.md) adds a separate bounded
provider receive buffer, receive-age failure, and complete clearing/suppression
of retained generated audio, with captured-burst replay coverage.
The [playback continuity follow-up](playback-continuity.md) adds a bounded local
playback cushion and observes software silence separately from native underruns.

**Initial implementation checks:** `mix ci` passed on macOS and via `ssh linux`, each with
**51 ExUnit tests**, two native Rust tests, 100 Credo/ExSlop checks, zero ExDNA
clones, no Credence findings, and zero Dialyzer errors or suppressions.

### Work progress and clarification recovery

The follow-up adds `Parlora.status/1`, correlated result-delivery events, bounded
context rechecks, and `/status` plus readable work/context diagnostics in the example.
The application policy waits two seconds for a usable order number, submits one
clarification if needed, and accepts a number-only reply. An unrecognized correction
holds the old result until interpretation is resolved. Rejected clarification
attempts remain observable without automatic retries.

The deterministic suite now contains **64 ExUnit tests**. Session tests distinguish
pending delegation, observed backend start, completed work awaiting context
acceptance, correlated acceptance/rejection/unknown outcomes, and independent
audio queue/handoff evidence. They verify that status excludes transcript and
result contents and does not assign playback to a particular result. Recovery
tests exercise missing numbers, late captions before the deadline, number-only
replies, correction while an old result completes, duplicate prevention, rejected
clarification, and invalid recheck durations. Late correction delegations associate
with the current task without duplicate work or replayed results; stale associations
and batches that revise the same task are rejected. Status-question caption tests
preserve the known order without clarification or holding its result, while keeping
an unrecognized correction unresolved even when followed by a status question.
These tests use in-memory adapters
and a fake backend; they do not establish a fresh live model or physical playback
measurement. Existing physical Linux audio limitations remain unchanged.

The updated `mix ci` passes on macOS and through `ssh linux` with the pinned
toolchains, including all 64 tests and the full quality checks.

A user-provided live transcript on September 16 confirms the correction flow with
the new diagnostics: order 123 completed as stale, order 124's context append was
acknowledged, its delivery status appeared in assistant captions, and the session
finalized at 31 seconds. It also exposed a late delegation left pending, now covered
by the association regression. That live run did not exercise the missing-number
clarification path or `/status` playback observations. A subsequent user-provided
run finalized at 33 seconds and confirmed the late delegation's association with
revision 2, with no duplicate lookup. It exposed an unnecessary clarification for
“Are you checking my order?” despite the known order 123. The example now recognizes
common status follow-ups and retains the previous request; a later unrecognized
correction still requires clarification. Both new regression tests failed before
this fix and pass afterward. The next user-provided live run, also finalized at
33 seconds, confirmed no clarification on the status question, holding the old
result while the correction arrived, stale-result rejection, delegation association,
and acceptance plus assistant captions for order 124. Missing-number clarification
and `/status` playback observations remain untested live.

`mix ci` runs warnings-as-errors compilation, formatting, ExUnit, native
format/Clippy/tests, strict Credo plus ExSlop, ExDNA with zero allowed clones,
Credence with strict Unicode assumptions, and Dialyzer. CI configuration runs the
same command on macOS and Linux with the pinned BEAM/Rust versions. Hosted CI
will execute after the repository is pushed; local/SSH results are recorded here.

Credence 0.8.1 recompiles and purges analyzed modules. Its semantic pass runs in
disposable processes; AST checks also cover tests/examples. No checks are disabled
or source rewritten. Mint.WebSocket 1.0.6's `new/4` spec incorrectly intersects a
new socket's nil fragment with a tuple-only opaque type. The documented `new/5`
call with explicit active mode avoids that incorrect spec; the live handshake
and Dialyzer both pass without warning suppressions.

`mix hex.build` produces a single source package, including both Cargo lockfiles
and `mix.lock`, without native target artifacts, development checks, or secrets.
An unpacked production consumer compiles with warnings as errors and starts with
`config :parlora, native_audio: false`, without devices, credentials, Rust/native
compilation, or development-quality dependencies in its runtime. No license was
selected in the brief: package license/link metadata is empty, so Hex emits the
expected missing-license warning. The package is built locally and unpublished;
choose a license and project links before public distribution.


## Standalone consumer follow-up

A separate Mix application now consumes the built source package with native
audio enabled. Its own policy, Jido supervision, runtime configuration and
lockfile work on macOS and Linux, including assembled production releases.
See [consumer validation](consumer-validation.md) for assertions, the macOS live
smoke test, Linux virtual-device evidence, and remaining limits. Reproduce it with
`scripts/consumer.sh`; application setup is documented in
[the consumer guide](using-parlora.md).


The [bounded audio timing follow-up](audio-timing-investigation.md) adds per-poll
correlation and compares baseline, moderate CPU load and a known injected stall
through the standalone consumer. Normal macOS physical and Linux virtual runs
were clean; the injected stall validates the diagnostics. The original audible
gap remains unexplained. Buffering defaults are unchanged.


## Incoming Telnyx follow-up (Milestone 6)

The incoming Telnyx adapter, signed webhook/authenticated stream helpers, Mint
call-control client and standalone OrderDesk integration are implemented.
[Telnyx validation](telnyx-channel.md) records 164 library tests plus all required
quality/native checks on macOS and Linux, 84 tests and fresh source-package
production-release checks on each platform, all six live-network acceptance
scenarios, remote playback controls, measured bounds and verified routing cleanup.
Synthetic calls exercised real Telnyx, GPT-Live, TypeSafe, Jido and private review.
Human handset quality remains unverified; preserved failures and pre-readiness
input drops are included in the report. Original Milestones 1–3 retain their scope.

## Grok Voice 3.0

The third provider implements the existing client-delegation contract with pinned
`grok-voice-3.0`, explicit HIGH/NONE reasoning (HIGH by default), direct PCM24/PCMU8 audio,
finalized caller transcripts, and speakable context. Optional quiet/instruction
updates, context acknowledgment, usage, and transparent resumption are not
advertised. See [configuration and semantics](grok-provider.md) and
[Voice 3.0 migration evidence](../validation/grok/voice-3-20261017/README.md).
Readiness verifies the provider-reported model and reasoning selection. Earlier
[Voice Think Fast 2.0 evidence](../validation/grok/README.md) retains its original
model and does not qualify the new release. Synthetic probes establish
narrow protocol behavior; human/PSTN and production reliability remain separate
qualification requirements.
