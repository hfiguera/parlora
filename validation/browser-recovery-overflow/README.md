# Browser recovery overflow reproduction

See [the root-cause report](../../docs/browser-recovery-overflow.md).

- `evidence.json`: original numeric overflow trace, times relative to the first
  chunk of the retained burst. Earlier history is truncated by the live recorder.
- `replay.exs`: exact queue-transition replay plus a controlled recovery comparison
  using the production pipeline, bounded adapters and browser media output.
- `macos-replay.log`, `linux-replay.log`: successful assertions on both platforms.

```sh
MIX_ENV=test mix run validation/browser-recovery-overflow/replay.exs
```

No credentials, network or physical device required. The failing controls are
expected diagnosis evidence. The fixed policy is also exercised in all ten millisecond browser clock phases.
`macos-fixed-replay.log` and `linux-fixed-replay.log` retain those outcomes.
The harness is shared with `test/playback_pressure_test.exs`, so it runs in CI.
Native and CI evidence is recorded separately; this deterministic replay does
not establish physical listening quality.
