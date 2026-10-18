# Clarifying an ambiguous follow-up on the current order

The first human Telnyx call completed correctly but asked for the order number
again after “Do you know what it is order,” although 124 was current. Replaying
reconstructed context reproduced target 124 at 0.65 and an ambiguous intent;
both were below the unchanged 0.8 execution threshold. The application asked
for the number, then still needed the operation after the caller repeated 124.
These are replay probabilities, not retained judgments from the original call.

The TypeSafe instructions now distinguish uncertainty about the operation from
uncertainty about its target. As a deterministic safeguard, AppPolicy can frame
an operation question around the current order when the classifier selected that
same order but is uncertain. It does not fill an unknown target, override a
changed/conflicting reference, dispatch speculative work, or lower the threshold.
Only clarification wording uses this safeguard; normal job admission is unchanged.

The session regression proves a caller can answer “The item's list” without
repeating 124 and get one items job. Changed, unknown and conflicting targets
still request the number. All 86 consumer tests and formatting pass on macOS
and Linux. `before.json` retains the original four replay cases; `after.json`
contains six passing live TypeSafe cases, including an operation-only reply
and a different, unnamed order. It is not a new end-to-end phone call.

From the synchronized standalone consumer:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/telnyx/policy-regressions/followup/check.exs
```
