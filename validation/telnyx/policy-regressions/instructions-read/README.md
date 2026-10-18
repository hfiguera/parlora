# Delivery instructions and provider close regressions — 2026-09-18

The manual Telnyx call exposed three independent issues:

- The delivery extractor stopped at the first ASCII period in `left in the,
  front box... in my patio`. The suffix was transcribed before draft admission.
  It now preserves runs of dots as pauses within the literal draft text. Single
  sentence terminators still end extraction. Destinations over 260 characters
  are rejected rather than silently truncated; incomplete destination tails
  still wait for clarification. Saving still requires exact browser approval.
- `Okay, and the delivery instructions are` was uncertain in the application
  classifier even though the voice provider answered. The prompt now distinguishes
  elliptical requests to read saved instructions from edits with or without a
  destination. The 0.8 confidence threshold and unknown-target guards are unchanged.
- After handset hangup, stopped session pipelines could no longer drain provider
  audio, but the OpenAI adapter kept buffering it while closing. Tail audio could
  trip the 750 ms age limit before final usage arrived. Close now clears both
  audio queues and ignores subsequent generated audio, while continuing to process
  acknowledgments and final usage until the existing shutdown deadline.

## Evidence

`before.log` contains reconstructed live TypeSafe judgments from diagnosis, not
probabilities retained from the original call. `check.exs` runs seven read-only
live classifier cases and exercises the real application policy. `after.log`
records the corrected phrase and two equivalent read requests dispatching saved
instructions lookups without clarification. Controls preserve edits, missing
edit text, an unspecified different order, and refusal. The refusal control
checks classification; its policy snapshot deliberately has no stored draft.

Run from the standalone consumer with `ORDER_DESK_DATABASE=:memory:` and
`ORDER_DESK_TYPESAFE=1`, through `scripts/with_keychain.py mix run` followed by
this script's absolute path. Secrets are never included in the output.

`test/openai_shutdown_test.exs` exercises the production adapter through Mint
and a local WebSocket peer. It checks stale retained audio at close, oversized
and malformed tail audio, final usage acknowledgment, finite timeout without an
acknowledgment, and the unchanged active-call stale-audio failure. It does not
replace the adapter event handler or connect to OpenAI.

The consumer's `app_policy_test.exs` verifies exact full draft text across ASCII
and Unicode ellipses, ordinary sentence boundaries, incomplete tails and
oversized destinations.

- macOS and Linux: `mix ci` passes, 171 tests passed, 3 excluded; native checks,
  Credo/ex_slop, zero-clone ex_dna, Credence and Dialyzer pass.
- Consumer: 96 tests pass on macOS. The initial Linux run alongside library CI
  hit the pre-existing greeting test's 100 ms subscription wait (95/96 passed);
  `linux-consumer-first.log` preserves that result. An unchanged isolated rerun
  passes all 96 tests and is recorded separately in `linux-consumer.log`.
- Live TypeSafe replay: all seven cases pass their expected semantic checks.

No new handset call is claimed. Provider finalization is verified against a
local protocol peer; live carrier shutdown and perceived audio quality still
require a new call. Previously saved truncated text is not changed automatically.
