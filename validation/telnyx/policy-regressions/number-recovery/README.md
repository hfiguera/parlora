# Numeric continuation and clarification recovery — 2026-09-18

## Behavior

- Numeric cardinal prefixes ending in zero (100, 120, 990) receive the same
  default 600 ms settling window as extendable spoken cardinals.
- Supported mixed cardinals (120 three, 100 twenty three) normalize for number
  extraction. Late continuations reconstruct the request even after the prefix
  lookup completes. Additional numeric digits are never appended to guess an ID.
- When an application clarification exists, its recorded context revision
  identifies fresh caller input. The policy sends `clarification_reply` with that
  text and the previous operation to TypeSafe. Candidates include numbers parsed
  from that isolated reply, even if overlapping speech joins earlier malformed
  input in the complete transcript. The prompt explicitly treats a bare complete
  number as an answer to the outstanding request, and still permits a new intent.
- The 0.8 confidence threshold, finite queue limits and browser-only write
  authorization are unchanged. This is consumer application logic; no library
  API or telephony adapter changes.

## Evidence

- `diagnosis.md`, `before.log`, `controls.log`: reconstructed diagnostic replays,
  not the original call's classifier probabilities or exact ASR timestamp trace.
- `check.exs` / `after.log`: **8 live TypeSafe/policy cases passed** using jev-1.13.0:
  cardinal reply, digit reply, preservation of items operation, changing to items,
  initial clarification before any job, mixed continuation after a completed
  numeric prefix job, missing new order, and conflicting numbers. The last two
  request clarification; the others create the intended work.
- Consumer `number_continuation_test.exs`: six added offline regressions cover
  parser boundaries, timely/late tails, fresh replies despite joined history,
  initial delegation recovery, and an integrated fragmented reply through the
  session, Jido, result delivery and delegation association.
- **95 consumer tests passed on macOS and Linux**, with format checks passing.
- All **10 browser-acknowledgment live cases** passed with this prompt; saved and
  pending drafts, verification reads, corrections and refusals remain distinct.

Run the bounded replay from the standalone consumer:

```sh
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/telnyx/policy-regressions/number-recovery/check.exs
```

This reads the existing Keychain credential into the child environment, uses an
isolated database, and does not place calls or mutate the manual-call records.

The previous six-case live ambiguous-follow-up replay also passed; see
`followup-after.json`.

## Limits

A finite settling delay cannot identify the end of speech: a sufficiently long
pause can still admit a prefix first. The late-continuation tests verify recovery
in that case. Only the documented three-digit cardinal grammar is normalized;
ambiguous or malformed input must not be interpreted as arbitrary arithmetic.
Classification remains model-dependent. No new human handset/audio retest is
claimed by these automated checks.
