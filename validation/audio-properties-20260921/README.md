# Audio property tests — September 21, 2026

Base revision `ca7ff87`, with the uncommitted property suite and partial-frame fix.
StreamData 1.4.0 is locked and test-only. ExUnit and StreamData are included in
the test Dialyzer PLT; no warning exclusions or existing gate thresholds changed.
See [property definitions and commands](../../docs/audio-readiness.md#property-tests).

## What randomized testing found

The first seed (`20260921`) shrank a browser failure to:

```elixir
[write: 96, write: 385, tick: 7, tick: 4, tick: 2]
```

Write amounts are samples, not milliseconds. The generated sequence ran after
the harness's guaranteed initial write/play/clear/stale-write prefix. A simpler
standalone regression now writes 96 and 385 samples, then drains playback.

Those fragments total 962 bytes, two bytes more than a 960-byte queue read.
The old browser Media code popped only the first 192-byte fragment because the
770-byte second fragment could not fit the remaining budget. It then padded the
first fragment with silence despite more source audio being queued. A separate
241-sample regression verifies that a partial staged tail is still source audio
when the queue is empty; previously it was combined with generated silence and
marked as non-source output.

The fix continues filling a 10 ms output packet from queued fragments before
padding and preserves a final staged tail when no queued data remains. Queue
capacity is unchanged; post-packet staging remains less than one configured
maximum frame (960 bytes). The ordered-byte model checks every accepted,
uncleared sample still pending, and a separate Opus encoder checks each emitted
packet against the expected stream. Native resources must close after each run.

The first run also rejected this proposed continuity case:

```elixir
# 200 ms immediately, then 10 ms at 217 ms, then a one-sample tail.
[{200, 0, false}, {10, 17, false}]
```

This is an invalid *unconditional no-gap requirement*, not corruption: a 200 ms
initial packet fills a queue-based startup cushion early and can run out before
the next delayed packet. The normal property follows the documented variable
packet envelope (at most 100 ms and 20 ms jitter). The adverse property still
generates 200 ms packets and up to 300 ms jitter and requires exact source
preservation, bounds and cleanup, allowing gaps. A deterministic test retains
this envelope counterexample. No prior continuity gates were weakened.

`initial-findings.log` preserves both initial failures. The production bug was
independently confirmed by substituting the committed old Media implementation
in a separate Mix VM: the two deterministic regressions and the browser property
all failed (`original-media-negative-control.log`). Reproduce that expected
failure without changing project files or a running server:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  mix run --no-start validation/audio-properties-20260921/reproduce_old_media.exs
```

## Validation scope

The six properties cover normal/adverse arrival sequences, overload rejection,
ordinary recovery history, finite short-tail draining and browser control
sequences. Generated packet descriptions and commands shrink directly; large
PCM payloads are constructed afterward. Default CI runs 50 cases per property.
The larger exploration uses 1000 cases per property with seed 20260921 on macOS
and 20260922 on Linux, on Elixir 1.20.4 / Erlang 29.0.6.

An initial Linux CI attempt under overlapping work failed an existing Twilio
test that expects a second pull before its real-time 20 ms deadline. The log
is retained as `linux-initial-ci-findings.log`. Property modules now run
synchronously to avoid adding CPU pressure to asynchronous timing tests. The
Twilio test itself and its timing assertions are unchanged. That log also
contains the initial missing-PLT diagnostics, resolved by including the test
dependencies in Dialyzer's test PLT.

These tests do not claim live provider, physical device, telephone receiver,
arbitrary network or perceptual validation. Browser control properties run
production callbacks, media processing and Opus, but not ICE/DTLS or a physical
speaker. The separate decoded-browser suite covers the actual WebRTC path using
generated reference audio. No API credentials or microphone are used.

## Results

- macOS seed `20260921`: 1000 runs per property, **6000 generated cases passed**,
  plus all three deterministic examples (`properties-macos-1000.log`).
- Linux seed `20260922`: 1000 runs per property, **6000 generated cases passed**,
  plus all three deterministic examples (`properties-linux-1000.log`).
- Final `mix ci` on both platforms: **232 passed (6 properties, 226 tests),
  3 excluded**, including the default 50 runs per property. Native checks,
  strict Credo/ExSlop, ExDNA, Credence and Dialyzer passed (`ci-*.log`).
- The unchanged Twilio timing test passed its isolated Linux recheck with the
  original seed and the final full suite (`twilio-recheck-linux.log`).
- macOS decoded-browser gates: **7/7**, PCM matrix **200/200**, analyzer negative
  controls **9/9**. Reports are in `macos/`.
- Linux decoded-browser gates: **7/7**, PCM matrix **200/200**, analyzer negative
  controls **9/9**. Reports are in `linux/`. Both decoded suites passed on the
  first run of this change.

The normal-envelope correction was a test-specification change; it is retained
explicitly in the counterexample and does not remove the adverse case from the
generated suite. The partial-frame fixes change production Browser.Media.
Its tested SHA-256 is
`4f09d731e8ad162c9aabe12aff391a9ae4c370ef70f32197db71e24565aa5577`.
Large generated receiver WAV/WebM captures remain under
`/tmp/parlora-properties-gates-macos` on the development machine.
Linux captures remain in `/tmp/parlora-properties-gates-linux` on the Linux host.

The local example was rebuilt from the package, all 70 library source files
matched this checkout, and the idle server restarted at `http://localhost:4000/`.
Health reported zero active sessions. Its log is
`/tmp/parlora-browser-properties-20260921.log`; numeric timing traces go to
`/tmp/parlora-browser-properties-20260921-traces`. No new live call or physical
listening result is claimed.
