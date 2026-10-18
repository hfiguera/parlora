# Playback continuity — September 16, 2026

Historical measurements below used the 60 ms cushion. Current defaults and the
September 20 correction are documented in [playback recovery](playback-recovery.md).

## Finding and change

The local channel previously consumed generated frames immediately. When uneven
delivery briefly emptied its queue, it inserted 10 ms of zero PCM and sent that
successfully through Rubato/CPAL. Those inserted gaps did **not** increment the
native underrun counter: the device had samples, but some were locally fabricated
silence between pieces of source audio.

A continuous ten-second tone delivered in 100 ms chunks with alternating 20 ms
arrival jitter reproduced this with the real macOS device path. The original
probe inserted 50 ms of silence. The later paired run measured 40 ms; exact
scheduler timing varies. This is a concrete source of short gaps, distinct from
the previously fixed provider receive overflows.

LocalAudio now uses a **60 ms playback cushion**. At initial playback and after
starvation, it waits until 60 ms of PCM is available or until 60 ms have elapsed
since the first available frame. The timeout ensures a short tail is eventually
played even without subsequent frames. Once playing, it consumes available audio
normally. Clear resets this state and discards retained audio through the existing
pipeline/channel/native path.

Configure `playback_buffer_ms` in LocalAudio's adapter options (0–200, default 120).
The current default is adaptive, with a 200 ms ceiling and a separate 120 ms
recovery cap; see [the current policy](playback-recovery.md). Earlier measurements
below describe their original fixed settings.
Zero disables the cushion for comparisons. The requested amount must fit the
configured Elixir playback queue. This adds up to roughly 60 ms of initial/recovery
waiting, plus polling and existing device delays. The native target stays 30 ms;
queue capacities and the provider receive buffer remain unchanged.

## Paired physical/virtual validation

Each run delivered identical, continuous 440 Hz tone media for ten seconds,
through the normal audio pipeline and CPAL/Rubato path. Only the local playback
cushion changed. The source arrived in 100 ms chunks at alternating 100 ms and
120 ms offsets (120/80 ms delivery intervals). Measurements count locally inserted
silence between the first and last consumed source frames, excluding startup/tail
silence. Every run consumed all 10,000 ms of source media.

| Measurement | macOS built-in audio | Linux virtual loopback |
| --- | ---: | ---: |
| Inserted silence, cushion disabled | 40 ms / 4 blocks | 30 ms / 3 blocks |
| Inserted silence, 60 ms cushion | **0 ms / 0 blocks** | **0 ms / 0 blocks** |
| Native underrun frames after warmup, both runs | 0 | 0 |

Native totals included startup underruns (4 frames on macOS, 1,508 on Linux),
measured separately from steady operation. The source/silence measurements are at
conversion input; they are not a recording of the acoustic output or proof that a
person heard every sample. Physical Linux audio remains unverified. The synthetic
native callback harness is not a substitute for these hardware/virtual timing runs.

[Machine-readable results](playback-continuity-results.json) retain numeric reports
and the live-run summary without raw audio or transcript content.

## Live validation and limits

A 90-second macOS GPT-Live exercise completed three backend requests and finalized
with 89 seconds of provider usage. There were no provider output overflows or
post-start capture overflows. It recorded five native output-underrun observations
and 16 new `:playback_starved` observations; the exercise includes intentional
clear/suppress/resume operations and conversational pauses.

Those starvation observations establish that the source queue emptied after
playback began. They do not establish whether the affected samples contained
speech or silence, and cannot all be classified as intentional from this summary.
The cushion fixes the controlled small-jitter reproduction; this live run does not
prove all possible audible gaps are gone. Larger stalls can still exhaust the
cushion. Increasing latency indefinitely is not the solution.

The current suite covers deterministic jitter replay with exact source-byte order,
short-tail release, starvation/rebuffer transitions, and reset behavior, alongside
the existing clear/resume and bounded-queue tests.
`mix ci` passed on macOS and Linux: 74 regular tests, native checks, Credo/ExSlop,
ExDNA, Credence, and Dialyzer. The separate three-test stability suite also passed
on both platforms.

## Observability and reproduction

`LocalAudio.observations/1` now includes cumulative `playback_source_bytes`,
`playback_silence_bytes`, and `playback_starvations`. Silence totals include startup,
idle time, suppression, and buffering waits; they are not an audible-glitch count.
A transition from active playback to an empty source queue emits
`:audio_discontinuity` with `cause: :playback_starved`, playback epoch, suppression
state, and configured cushion.

`[:parlora, :audio, :playout]` telemetry reports source bytes, inserted silence bytes,
remaining queue bytes, and peak sample amplitude per converted input block. These
numeric observations retain no raw audio. Native underruns remain separate.

```sh
# macOS: test-only memory provider feeding actual local devices
MIX_ENV=test PARLORA_PLAYBACK_BUFFER_MS=0 mix run scripts/playout_validation.exs
MIX_ENV=test mix run scripts/playout_validation.exs

# Linux: temporary virtual sink, with the configured native toolchain environment
MIX_ENV=test PARLORA_PLAYBACK_BUFFER_MS=0 scripts/linux_audio.sh scripts/playout_validation.exs
MIX_ENV=test scripts/linux_audio.sh scripts/playout_validation.exs
```

Use the documented macOS `ERL_FLAGS` busy-wait settings and pinned Rust toolchain.
The script accepts the existing `CPAL_HOST`, `CPAL_INPUT`, and `CPAL_OUTPUT` device
selection variables. Its generated tone has amplitude 300/32768. The 60 ms mode
asserts zero inserted mid-stream silence in this controlled workload and verifies
that all source audio was consumed.


## Standalone consumer follow-up

A caller reported a brief gap near the end of a 31-second standalone consumer
session. Order correction and finalization succeeded, but its pasted transcript
contains no audio timing/counter evidence, so the cause of that gap is unresolved.
The vendored LocalAudio implementation matches the repository and retains the
60 ms cushion; the launcher also retains the macOS scheduler settings.

The example's progress printer had silently ignored `:audio_discontinuity` events,
including source-queue starvation and native device underruns already emitted by
Parlora. Both launchers now print these with elapsed milliseconds and selected
numeric/control metadata. `/mark` adds a caller-reported timestamp for comparison.
Events during graceful close are also displayed within the existing six-second
wait deadline. The consumer fixture and development consumer carry the same change.

This adds evidence for the next reproduction; it does not establish a root cause
or change playback buffering. Queue starvation can occur at natural pauses, and
native underruns can occur during startup/controls. Correlate notices with the
reported time before attributing an audible defect. No raw audio is recorded.

Validation for this diagnostic change: macOS `mix ci` passed with 76 regular
tests (3 excluded stability tests), native checks, and all quality checks. The
standalone consumer compiled, passed formatting, and passed both integration
tests. No new live reproduction or Linux audio measurement was performed for
this console-only change.


## Bounded timing follow-up

The [subsequent timing investigation](audio-timing-investigation.md) compared
baseline, moderate CPU load, and a deliberately injected local stall on macOS
physical audio and Linux virtual audio. Ordinary runs were clean; the injected
control validated the new per-poll evidence. The original live cause remains
unresolved, and playback buffering remains unchanged.
