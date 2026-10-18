# Clarification reply context — 2026-09-20

## Observed call

Browser call 19:38:46–19:39:55 on localhost:4201, after pressure-aware recovery
was deployed. The 123 → 124 correction completed two backend jobs and both results
were accepted. The later transcript was:

1. Caller: “Do you know what it is, order”
2. Assistant: asks what about the order should be checked.
3. Caller: “One hundred twenty three”
4. Assistant: says it will check, then asks for the three-digit number again.
5. Caller: “one hundred twenty four, one two four”
6. Assistant: asks what about the order should be checked.

The UI recorded three clarification requests and no subsequent job. No provider
output overflow or failure-driven closure appeared. Eight playback-starvation
observations do not establish audible speech loss. The retained visible page is
locally saved at `/tmp/parlora-browser-call-20260920-1938.txt`.

The first request is ambiguous as transcribed; asking whether the caller means
items, status or something else is reasonable. A number-only reply does not itself
answer an operation question. The defect is not that every clarification must
be replaced with a speculative lookup.

## Confirmed defects in the baseline (`c2e09c1`)

### Clarification purpose is missing from interpretation

`Parlora.Session.ContextWait.clarify/3` stores only `context_revision` and
`command_id`. `OrderDesk.AppPolicy.clarification_reply/3` supplies only fresh caller
text and the last task's operation. `CallerHistory.text/1` uses assistant fragments
as boundaries but discards their wording. No classifier input identifies the
actual clarification question or the unresolved field.

The deterministic replay constructs two snapshots differing only in the question:
“Can you tell me the three-digit order number again?” versus “Can you tell me what
about the order you want checked?”. A reply of “One hundred twenty three” produces
**identical classifier input** in both. `previous_operation` is `status`, borrowed
from the already completed order-124 task, although the new follow-up's requested
operation has not been resolved. Therefore the interpreter cannot distinguish
supplying a missing target from changing the target of an unresolved operation.

### Repeated equivalent numbers are rejected by literal extraction

`Speech.numbers/1` greedily matches a comma-separated run of number words and tries
to parse the entire run as one cardinal. Its constrained grammar rejects:

| Input | Extracted IDs |
| --- | --- |
| `one hundred twenty four` | `["124"]` |
| `one two four` | `["124"]` |
| `one hundred twenty four, one two four` | `[]` |
| The same two forms separated by a newline | `["124"]` |

This is a real extraction defect, but it is **not sufficient to explain the whole
call**: 124 remains an available candidate from history/active task, and the live
classifier replay identified that target confidently anyway.

### Uncertainty is not retained as a structured pending request

`Interpretation.interpret_answers/1` requires 0.8 confidence for both operation and
target. Rejecting an uncertain operation is correct. However, the application's
recovery stores no independent resolved target/unresolved operation. Its wording
guard favors the existing task's order: uncertainty around a different target can
produce another number request even when that new number was literally extracted.
The deterministic injected-judgment control demonstrates that path for 123.

## Baseline bounded live classifier replay

The original `replay.exs` and `results.json` describe the baseline before the fix.
Run that historical probe against `c2e09c1`, from the separate consumer using its
existing secure Keychain wrapper:

```sh
cd /Users/humberto/Projects/parlora_consumer
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/clarification-reply-context/replay.exs
```

No live voice session or saved order is changed. The replay invokes the actual
`AppPolicy`, current TypeSafe questions/model and normal 0.8 confidence policy.
It performs deterministic checks plus two rounds of four live classifications.
`results.json` preserves constructed inputs, answers and decisions.

| Constructed reply | Two live replay outcomes |
| --- | --- |
| Bare 123 after operation question | Status/123 accepted; target confidence 0.81/0.83 |
| Repeated 124 after number question | Target confidence 1.00/0.99, intent confidence 0.62/0.64; both request operation clarification |
| Single “one two four” | Status/124 accepted; intent confidence 0.82/0.81 |
| Explicit “What items are in order 124?” | Items/124 accepted; intent confidence 0.99 both times |

The confidence values are classifier output, not calibrated guarantees. The
original call's raw classifier requests/scores and exact submitted question texts
were not retained. The replay uses consolidated caller captions with constructed
revision numbers and boundaries, not an exact streamed-snapshot reconstruction.
It reproduces the final repeated-number behavior and proves the context-loss and
parser defects. It does **not** reproduce or conclusively attribute the original
bare-123 re-ask; that may involve streaming snapshot differences, classifier
uncertainty or provider wording. The UI's failures/uncertain counter aggregates
errors and does not establish API outages.

## Correction design

Keep the pending request in application-owned interpretation state: the known
order, known operation if any, unresolved fields, and the question asked. Treat
number and operation replies according to that state, preserving a confidently
identified target while asking only for unresolved information. Do not infer
items from the ambiguous ASR phrase or blindly reuse an old completed operation.
Recognize equivalent repeated ID forms without collapsing conflicting numbers.
Retain bounded, nonsecret judgment/clarification evidence so the next live failure
can be traced to the actual submitted snapshot. Keep the confidence threshold and
write-confirmation requirements unchanged.

## Implemented correction and verification

The library now retains the submitted question and an opaque, bounded application
map on each clarification. The consumer stores the known order, known operation,
and missing fields there. It recognizes equivalent repeated IDs and keeps conflicting
IDs distinct. A number-only reply to a missing-operation question updates the
known order and asks what to check; it cannot start a job by guessing the operation.
TypeSafe receives the partial request and the pending order as an offered choice,
with explicit precedence over the older task for replies to the pending question.
Confidence thresholds and page authorization for saving drafts are unchanged.

The regression suite exercises the complete synthetic-session sequence, retained
orders after transcript trimming, pending items versus previously completed status,
repeated/conflicting/unfinished numbers, and the library's 4,096-byte map bound.

Run the corrected bounded live probe from the standalone consumer:

```sh
cd /Users/humberto/Projects/parlora_consumer
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/clarification-reply-context/verify_fix.exs
```

`fix-results.json` records two deterministic controls and six live TypeSafe calls
(two rounds of three cases), all passing:

- A missing-operation question followed by bare 123 or repeated 124 asks what to
  check about that supplied order, without running the classifier or starting work.
- “What items are in that order?” uses retained order 123 despite completed status
  work for order 124 and a transcript no longer containing 123.
- Repeated 123 after an items-number question starts items/123.
- Repeated 123 after a status-number question supersedes with status/123.

The initial live attempts exposed two additional integration gaps. Their evidence
is preserved in `first-fix-results.json` and `second-fix-results.json`: the retained
order was absent from allowed choices; after adding it, older instructions and
candidate descriptions still preferred the completed task. The final code fixes
both. No confidence check was relaxed to make the probe pass.

Validation on macOS and Linux: library `mix ci` passed (185 ExUnit tests, three
excluded live/device tests, native checks, Credo/ExSlop, ExDNA, Credence, Dialyzer).
The final consumer suite contains 112 tests, including preservation of the
known operation when asking the caller to finish a partial number. These checks and live classifier
calls do not reproduce a full microphone conversation, prove transcription quality,
or identify the original bare-123 re-ask with certainty. The original raw judgments
remain unavailable. A fresh browser call is the next end-to-end confirmation.
