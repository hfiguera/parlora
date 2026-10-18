# Recovery regression fix validation — September 21, 2026

Base revision: `7816663a25354650c92d1b960d5c185c5f8cbd3c`, with uncommitted
corrections and tests. Tested `lib/parlora/playout.ex` SHA-256:
`248f6bb042a1bb5fb5da30ad4c32fabbe1aea14c2917a7f2e4e3698200befe6f`.
Both OS runs use the pinned Elixir 1.20.4 / Erlang 29.0.6 toolchain.

| Check | macOS | Linux |
| --- | --- | --- |
| `mix ci` | 223 passed, 3 excluded; all required checks passed | 223 passed, 3 excluded; all required checks passed |
| Deterministic PCM gates | 200/200 | 200/200 |
| Decoded-browser gates | 7/7 | 7/7 |
| Analyzer negative controls | 9/9 | 9/9 |

`mix ci` includes native format/Clippy/tests, strict Credo with ExSlop, ExDNA,
Credence and Dialyzer. The three excluded tests require hardware/live/stability
conditions; these results do not claim new physical microphone/speaker or live
GPT-Live validation. Linux physical audio remains unverified.

The decoded-browser cases cover steady, jitter, burst, variable chunks,
interruption, disconnect and reconnect. Actual Chromium receives production
WebRTC/Opus output from a synthetic source on a dedicated local listener. Both
platforms passed the existing thresholds on the first run of this correction.
Per-case browser/analysis reports, matrix results and library hashes are retained
in `macos/` and `linux/`. Linux is an rsync mirror without Git metadata; its
source hashes identify the tested code. WAV/WebM fixture captures remain in
`/tmp/parlora-current-shortage-gates-{macos,linux}` on the respective hosts.

The original adaptive-policy failures remain in the parent directory and
`observed-sequence.json`. Across ten complete 20-second source sequences, the
observed policy failed the new ordinary-recovery-wait gate in all ten phases,
with up to 100 ms added wait. The corrected policy passed all ten, with at most
10 ms (`fixed-sequence.json`). Unlike the isolated recorded-gap comparison,
these runs preserve continuous pipeline/playout state across the entire schedule.
Every source sample, including quiet samples, is compared exactly.

`recorded-replay.json` separately preserves the exact reproduction of all twelve
observed gap durations using the saved failing policy, and compares the corrected
policy on each window. Browser.Media regression tests verify the three reported
nonquiet-boundary gaps now insert 70/30/50 ms instead of 150/70/100 ms, with
source bytes preserved. This is still evidence of residual source absence,
not a claim of gap-free speech.

The packaged consumer library was rebuilt and all 70 library source files were
verified byte-for-byte against this checkout. The example restarted at
`http://localhost:4000/`; health reported zero active sessions. The new launch
logs to `/tmp/parlora-browser-current-shortage-20260921.log` and saves numeric
timing traces to `/tmp/parlora-browser-current-shortage-20260921-traces`.
No live listening call was performed as part of these automated checks.
