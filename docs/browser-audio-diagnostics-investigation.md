# Browser audio diagnostic investigation — September 21, 2026

## Finding

The latest manual OrderDesk browser call completed its workflow, and the caller
reported good audio. Its warnings have two distinct mechanisms:

1. Browser capture starts at WebRTC connection readiness, before the session's
   input pipeline starts draining it. The bounded queue fills during startup.
2. `playback_starved` measures a transition from queued source audio to an empty
   queue. It also fires when a finite clip ends normally, including silent clips.

These mechanisms are reproduced against the production browser media code. They
do **not** establish that the four playback observations in this particular call
were all normal endings, or that any were audible defects. The call retained no
sample-level evidence from which to make that distinction.

## Retained call evidence

The existing browser diagnostics showed these local times on September 21:

| Time | Observation |
| --- | --- |
| 10:46:36 | WebRTC connected; first capture overflow |
| 10:46:36–37 | Capture notices with cumulative totals 1, 26, 51, 77, 102 |
| 10:46:38 | Startup capture discarded; session ready |
| 10:46:42, 10:46:50, 10:47:01, 10:47:26 | Four playback-starvation observations |
| 10:47:31 | Disconnected |

No capture-overflow notice appeared after readiness. Notices are throttled to
one per cause per 250 ms, so 102 is the last reported cumulative capture count,
not a proven final count. All four backend jobs completed and their results were
accepted. The page showed the confirmed delivery instruction saved to order 124,
and the transcript included the assistant's automatic save acknowledgement.
The subsequent health check reported zero active sessions. No provider output
overflow was present in the retained diagnostics.

## Startup capture mechanism

`Browser.handle_info/2` starts media ticks when ExWebRTC becomes connected.
Each 10 ms tick invokes `Browser.Media.capture/2`, which creates a 480-byte,
24 kHz mono PCM16 frame. If decoded input is unavailable, it pads with zeros.
It pushes that frame into a 9,600-byte input queue: 200 ms of capacity.

The session starts its input/output pipelines only after channel, provider, and
backend all report readiness. Until then, no input pipeline drains the browser
queue. After 20 undrained ticks, further frames are rejected as `capture_overflow`.
The input pipeline deliberately discards the retained pre-ready frames at startup
and emits `startup_buffer_discard` before forwarding fresh input.

This is a readiness mismatch, not evidence of overloaded capture during the
conversation. Pre-ready audio really is dropped, but the warning does not identify
whether it contained speech, background sound, or generated silence. The UI asks
the caller to wait for the greeting. Enlarging the queue would retain more input
that the startup policy subsequently discards.

## Playback diagnostic mechanism

`Playout.take/4` increments `starvations` when the queue is empty and `playing?`
was true. It substitutes a 10 ms silence block and enters recovery.
`Browser.Media.fill_output/2` emits `playback_starved` when that count increases.

Neither check distinguishes a normal clip ending from temporary source starvation
within speech. The browser event contains only cause, epoch, and cumulative count.
The browser media path also lacks the per-block amplitude/source/silence telemetry
that LocalAudio uses for its numerical gap investigation. Transcript adjacency
does not establish precise playback position.

Recovery is real: with current defaults, newly returned audio can wait 200 ms
unless upstream pressure releases recovery early. This can extend a genuine gap,
but no retained timing evidence demonstrates that it happened inside speech in
this call. The reproduction isolates this behavior; it does not replay the call.

## Original reproduction and checks

From the repository root, using the pinned macOS toolchain:

```sh
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
mix run validation/browser/media_diagnostics.exs
```

The original probe exercised the production
Browser.Media, Playout, queues, and native Opus codec without network calls,
credentials, microphones, or speakers. Four checks passed:

- With no RTP input, 25 undrained capture ticks produce 20 queued silent frames
  and five overflows. After draining begins, 100 further ticks add no overflows.
- A finite 120 ms nonzero clip consumes all its source PCM without inserted
  silence, then emits exactly one starvation observation on the next empty tick.
- An entirely silent clip produces the same observation. Further idle ticks do
  not repeatedly increment it.
- A genuine gap between two nonzero clips produces the same event. With no
  upstream-pressure release, recovery contributes 200 ms of waiting after source
  audio returns.

Five existing targeted tests also passed (34 unrelated tests excluded): startup
capture discard/fresh forwarding, playback-refill replay, and starvation replay.
The running example's vendored Media and Playout source hashes match the root
implementation. No runtime behavior, buffer size, or running server was changed.
This investigation ran on macOS; it is not new physical Linux audio validation.

## Recommended follow-up

Distinguish intentional pre-ready capture discard from overflow during a ready
session. For playback, report the empty-queue observation without implying an
audible discontinuity, and collect bounded timing and signal-level summaries on
both sides of a gap. Preserve genuine overflow/error detection. Do not increase
buffers solely to eliminate these counters, or relabel every event as harmless.

## Implemented follow-up

Browser now discards/counts pre-read RTP and starts capture on the input pipeline's
first valid read. It does not fill the startup PCM queue. Playback source-queue
exhaustion is reported as `:audio_observed`, with bounded numerical gap summaries
and adjacent PCM peak levels, instead of claiming a discontinuity. Runtime buffers
and pacing are unchanged; capture overflow after readiness remains visible.

The [probe](../validation/browser/media_diagnostics.exs) now runs the eight
regression checks in [the test suite](../test/browser_diagnostics_test.exs):
startup discard and fresh capture, invalid reads, genuine ready-state overflow,
silent/nonzero normal clip endings, actual gaps with unchanged recovery timing,
clear/epoch isolation, bounded history and close outcomes, and signaling filtering.
The original four checks above describe the pre-change characterization.

Validation of the change:

- macOS and Linux `mix ci`: 201 tests passed, 3 excluded on each; native checks,
  Credo/ExSlop, ExDNA, Credence and Dialyzer passed.
- Updated packaged OrderDesk on macOS: 126 tests passed.
- Offline Chrome smoke: three successful media/control cycles, zero steady-state
  inserted silence, source-queue exhaustion, lost packets or concealed samples;
  disconnect/page-close cleanup in 6–28 ms. Permission denial, rejected Origin,
  and signaling-loss cleanup (29,937 ms) also passed.

[Numeric results](../validation/browser/media-diagnostics-results.json) retain
these outcomes. Browser smoke uses synthetic media and does not replace human
listening or classify the four observations from the original call. Physical
Linux audio remains unverified. The live macOS example was refreshed from the
updated package and its health check passed; no new live voice call was made.
