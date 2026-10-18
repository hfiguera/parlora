# Missing order candidate in the correction acceptance case

## Root cause

The example application's deterministic number extraction does not support the
abbreviated spoken-ID form **“one-twenty three”**. Consequently, it never offers
`123` to the TypeSafe target classifier. This is an application preprocessing
defect; adjusting the classifier prompt or retry delay cannot restore an option
that was omitted from its constrained choices.

Source: [failed live case](../validation/acceptance/results-after-overflow-fix/1-corrections.json).
The harness spoke “Check order one hundred twenty three.” GPT-Live returned these
caller deltas, in order:

```text
" Check", " order", " one-tw", "enty", " three"
```

`CallerHistory.text/1` preserves these fragments correctly as
` Check order one-twenty three`. No assistant fragment intervened. This is not
the earlier bug where overlapping captions split a number into separate caller
segments, and it does not require a race with a running job.

## Failure chain

1. `OrderDesk.Speech.numbers/1` tokenizes the hyphen correctly, yielding
   `one`, `twenty`, `three`.
2. `number_words/1` concatenates only sequences consisting entirely of digit
   words. Other sequences use arithmetic addition with an explicit `hundred`
   multiplier. Here it computes `1 + 20 + 3 = 24`.
3. The three-digit filter discards `"24"`. The result is `[]`, not `"123"`
   and not a lookup for order 24.
4. `AppPolicy.interpret/3` has no active task to add as another candidate, so
   `state.order_candidates` is empty.
5. `Interpretation.questions/1` builds the target choices from those candidates
   plus `unknown`. The only permitted target is therefore **`unknown`**.
6. The recorded policy events are settle, verification, and clarification. The
   final session snapshot has no tasks or jobs and a pending delegation with an
   acknowledged request for clarification. It is waiting for new caller input.
7. The acceptance runner waits for the first order-123 lookup before playing the
   corrections. Because no lookup starts and the script does not answer this
   unexpected clarification, it reaches its 150-second scenario deadline.

The raw TypeSafe answers and probabilities were not retained, so this diagnosis
does not invent their exact values. Empty target choices independently establish
why a valid constrained answer could not select 123. The recorded events and final
state agree with that mechanism. There was no provider overflow in this case.

## Offline verification

From the standalone consumer:

```sh
cd /Users/humberto/Projects/parlora_consumer
mix run --no-start /Users/humberto/Projects/parlora/validation/acceptance/replay_order_number.exs
```

Before the fix, the replay verified empty candidates and the sole `unknown`
choice, then used a simulated `status/unknown` answer through the production
policy's settle/verify/clarify path. The updated replay now verifies `123` reaches
the actual target question and admits the lookup after a simulated `status/123`
answer. It uses an in-memory database and makes no API requests. Both diagnosis
and fixed replay passed with the pinned Elixir/OTP toolchain. The maintained
fixture and standalone application are synchronized.

Before the fix, control inputs “one hundred twenty three”, “one two three”, and
“123” produced `["123"]`; “one-twenty three” and “one twenty three” produced `[]`.

## Implemented fix and validation

`OrderDesk.Speech` now recognizes abbreviated hundreds-plus-two-digit IDs, such
as “one-twenty three” (123), “eight twenty five” (825), and “one nineteen” (119).
Digit-by-digit and explicit-hundred forms still work. The bounded grammar rejects
malformed word groups instead of adding unrelated tokens into a plausible ID.
It preserves conjunctions inside groups and treats bordering conjunctions as
part of the surrounding request. It never substitutes a database order.

An extendable prefix such as “one-twenty” uses the existing 600 ms settle window,
just like “one hundred twenty”. If a caller stops there, 120 remains a valid
candidate. If the final digit arrives after that prefix's lookup completed,
the policy reconstructs the caller request and supersedes the old order. Separate
segments or a new request do not count as number completion.

Regression tests cover the recorded fragmented phrase at the real candidate and
TypeSafe-question boundary, grouped/legacy forms, invalid groups, prefix settling,
and late completion through a real session with a scripted provider.

- Final consumer suite: **56 tests passed on macOS and Linux**; formatting and
  compilation with warnings as errors passed.
- Updated offline replay: `123` is offered and its lookup is admitted.
- Deterministic acceptance: **6/6 passed**.
- Full live acceptance: **6/6 passed**, with zero recorded provider audio
  discontinuities. [Retained report](../validation/acceptance/results-after-spoken-id-fix/report.json).

The new live correction call transcribed the IDs as digits, so the original
abbreviated spelling is covered directly by the offline replay, not claimed as
a repeated live transcription. Bordering-conjunction cases were added and checked
offline after the live server started. Original failures remain preserved.
