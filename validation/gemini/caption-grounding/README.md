# Caption boundaries and delivery grounding — 2026-09-24

The human call exposed an inferred delivery date ("out for delivery today") and
two assistant replies joined as `change.Order 124`. These fixes were validated
with the production adapter, browser WebRTC, OrderDesk policy, TypeSafe, Jido and
isolated SQLite databases. Live calls used synthetic Samantha speech. No user
microphone, production order changes, or credentials are retained here.

## Changes

- Gemini assistant captions carry a locally generated `segment_id`. Fragments
  share it until generation completion, turn completion, interruption or resumed
  setup. Signaling preserves it and the browser starts a separate row when it
  changes. No timestamps, provider acknowledgments or playback evidence are invented.
- Unsegmented providers, including OpenAI, retain exact fragment concatenation.
  This fixes the observed Gemini boundary loss; it does not claim an authoritative
  response-boundary fix for providers whose transcript contract lacks boundaries.
- OrderDesk instructions and status-result context prohibit inferring dates or
  converting estimates into guarantees. Fixture 124's status checks now reject
  added timing; a separate fixture 123 test requires the supplied Friday estimate.
  This is a model grounding mitigation, not deterministic validation of every
  spoken fact. The conservative fixture checker also flags negated mentions of a
  date; it is intentionally not a general semantic evaluator.

## Deterministic checks

Both macOS ARM64 and Linux x86_64 passed the full root `mix ci` checks: **273
tests/properties**, native checks, formatting, Credo, zero clones, Credence and
Dialyzer. Both standalone OrderDesk suites passed **156 tests**. The JavaScript
caption and task-pilot suites passed **15 tests**. See [check logs](checks/).

The new caption test was also run against the original `HEAD` version of
`voice.js`: it fails specifically because separate replies merge. The fixed
version passes. Split words (`deliv` + `ery`), numbers and corrections remain
exact within a segment. Socket-level adapter tests cover same-message final
captions, generation completion, interruption and subsequent caption identities.

## Live evidence

[Evidence](evidence.json) retains every run's original status, source hashes,
reply checks and assistant fragments, including the failed evaluations.

- Initial Gemini campaign: **6/6 passed**, two repetitions each of status 124,
  correction 123→124 and browser-confirmed saves. All four status replies omitted
  an inferred date.
- Supplied estimate control: **1/1 passed**, saying "Order 123 is shipped and
  expected Friday. The tracking reference is DEMO-123."
- Human-sequence save checks wait for the draft prompt before clicking Confirm.
  The final Gemini run passed and had distinct draft/save segment IDs and rows:
  "I've drafted that instruction for order 124. Please review the text on the
  page and press Confirm to save it." Then, in a separate row: "The instruction
  to leave the package at reception is now saved for order 124."
- OpenAI status control passed. The final OpenAI save-flow control also passed.
  No OpenAI provider protocol or acknowledgment behavior changed.

![Separate draft and saved-announcement captions](captions.png)

### Retained evaluator failures

One earlier Gemini human-sequence attempt timed out on the valid prompt "Please
review the instructions on the page and confirm to save them." The matcher only
accepted a narrower word order. That run stopped before confirmation; it is not
counted as a completed save-flow pass. Its sibling attempt passed.

Two earlier OpenAI save checks timed out despite correct spoken content, because
the evaluator required `saved` and `reception` in the same sentence. Observed
wording included "Order one twenty-four is saved. The instruction is, leave the
package at reception." The updated matcher accepts an affirmative save followed
by an explicit resulting instruction; tests still reject negation, future saves,
and attempts to borrow a destination from an earlier draft. Original failed runs
remain failed in the evidence rather than being relabeled.

One initial Gemini save run announced a save without its exact destination, then
repeated it later with the destination. The final human-sequence run produced one
complete announcement. This work does not establish absence of future repetition
or optimal announcement latency.

## Running app

The development app at `http://localhost:4000/` was rebuilt with the changed
provider/application code and the internal browser reloaded. The existing saved
instructions on orders 123 and 124 remain at version 2. No files were committed.
