# Synthetic PCM clock investigation and fix

See [the investigation](../../docs/pcm-overflow-investigation.md) for the causal
chain, measured limits, correction, regression tests and live reproduction commands.

`evidence.json`, `native.log`, `sink.log`, and `device-clock.log` retain the original
failure and controls. `device-clock-fixed.log`, `native-fixed.log`, and
`fixed-summary.json` record the corrected clock and successful live PCM retest.
No provider buffer limits were enlarged. The fixed live run had no provider
overflow or blocked output ticks; three local playback-starvation events remain
visible in its log. This is not a physical playback quality claim.

Validation: `mix ci` passes on macOS and Linux: **174 tests passed, 3 excluded**,
plus five CPAL Rust tests, other native checks, Credo/ex_slop, ex_dna (zero clones),
Credence and Dialyzer. The CI logs are retained here. Native clock and offline
replay tests passed on both platforms; live provider measurements were on macOS.

## Starvation follow-up

See [the separate investigation](../../docs/playback-starvation-investigation.md).
`starvation-retest.log` and `starvation-evidence.json` retain the new timestamped
measurements. The recorded timings reproduce three gaps; a regular-arrival
control with identical playout timing has none. `starvation-macos-ci.log` and
`starvation-linux-ci.log` record the expanded checks: **176 passed, 3 excluded**
on each platform. This follow-up diagnoses playback buffering; it does not change
the playback policy or establish physical speaker quality.

## Playback recovery correction

See [the implementation and results](../../docs/playback-recovery.md). The final
policy removes both nonzero-boundary gaps in the original recorded-arrival model;
a longer trial also verifies the bounded recovery tradeoff. `playback-refill-trial.log`
and `refill-trial-arrivals.json` preserve the intermediate trial. Final live
evidence is in `playback-recovery-live.log` and `playback-recovery-summary.json`.
Full checks are in `playback-recovery-{macos,linux}-ci.log`: **180 passed,
3 excluded** on each platform. Physical playback remains unverified by these probes.
