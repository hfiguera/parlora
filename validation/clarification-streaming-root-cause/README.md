# Clarification streaming diagnosis — 2026-09-20, 20:03 call

## Scope and evidence limits

The browser call ran from 20:03:22 to 20:05:15. `call-visible.txt` preserves its
rendered captions and event log. Five clarification events preceded or accompanied
three successful jobs: items, saved-instructions lookup, and draft creation. The
page then saved the draft and the assistant announced the saved value. The initial
order-status request never reached a backend job.

The server's ordinary log contains startup information only. The browser does not
retain the full policy snapshots, per-delta provider timestamps, original TypeSafe
answers/confidences, or the exact pending-delegation map at each decision. Therefore
this investigation distinguishes reproduced code defects from attribution to a
particular decision in the original call. Replay revisions/timestamps are constructed;
these are not an exact recording of that call.

## 1. Clarification cuts off the prefix of a number still being spoken

`AppPolicy.current_input/2` takes only fragments after the clarification's
`context_revision` whenever a clarification exists. Unlike the task-completion
path, it does not reconstruct a continuing number across that boundary.

The deterministic control constructs overlapping speech with:

- Caller prefix: “Sorry, I mean one hundred twenty”.
- A clarification marker after that prefix.
- Caller continuation: “ four”.

`CallerHistory.text/1` correctly reconstructs the whole request and `Speech.numbers/1`
extracts 124. Nevertheless, the policy's incomplete-number guard sees only “four”,
skips the classifier entirely, and requests “Please finish saying the three-digit
order number.” Removing only the clarification marker makes the same full transcript
reach classification and admit status/124 with an injected confident judgment.

This is a confirmed code defect matching the call's missing-digit symptom. The
original marker's exact placement is unavailable, so the replay does not prove its
precise occurrence time. Increasing classifier confidence cannot fix this path:
the classifier is never called. Parlora also rejects policy results when their
snapshot revision is stale; this is not evidence that the core applied an obsolete
in-flight policy result.

## 2. A first incomplete-number clarification can omit the request's operation

The incomplete-number guard runs before semantic interpretation.
`Clarification.number_input/1` preserves a previous clarification's operation,
but returns an empty map when there is no previous partial request. For an initial
“Check order one two”, the deterministic replay asks for the remaining number
without ever consulting the classifier, and retains no requested operation.
There is no completed task to provide fallback context at this point.

The earlier fix handled pre-existing partial state and completed tasks; it did not
establish that state for this initial fragmented-request path. A later number reply
can consequently require another semantic clarification. This loss is proven by
the control, but the actual call also had a transcription defect: “one hornet twenty
three” extracts no three-digit ID. We cannot attribute the original first question
solely to this missing-state branch or safely reinterpret “hornet” as “hundred”.

## 3. The items question can fall below the semantic confidence threshold

A bounded live TypeSafe replay uses the actual caption “Do you know what items
ordered”, with no active task and pending order 124. In both rounds:

| Classification | Round 1 | Round 2 |
| --- | --- | --- |
| Selected intent | items | items |
| Selected intent score | 0.76 | 0.75 |
| Selected target | 124 | 124 |
| Target score | 0.99 | 0.98 |

The unchanged 0.8 rule rejects the intent. `Clarification.input/4` discards the
uncertain candidate as a known operation, and `question/1` offers the broad menu
instead of asking a targeted confirmation such as “Do you mean the items in order
124?”. This reproduces the extra items question with constructed state, not the
original hidden classifier response. Scores are model outputs, not calibrated
probabilities of correctness.

There is also a deterministic question-selection defect: an uncertain target
with a retained order and confidently selected items can produce `missing: []`
but still ask which operation the caller wants. The wording is selected solely
by whether `known_order` exists, not by the unresolved field or judgment conflict.

Lowering the confidence threshold would hide uncertainty rather than fix number
assembly or preserve the intended confirmation semantics.

## 4. Multiple pending delegations do not have explicit recovery ownership

Before any task exists, `AppPolicy` selects `Enum.find(pending_delegations, ...)`
and ignores the triggering delegation. It repeats the same selection in
`current_input/2`. Each delegation can carry a different clarification marker.

A control with an older pending entry `a` and newer entry `z` selects `a` even when
the trigger names `z`, losing the newer entry's retained order/operation context.
This is map enumeration, not a documented conversational recency or ownership rule.
The observed call had multiple pending delegations before its first job, so this
is a relevant risk, but their IDs/markers were not preserved. It is not proven to
have caused this call's extra question. In fact, the live replay using the older
marker admitted items/124 twice (intent 0.89), while the newer-marker replay above
asked for clarification. More context changes the classifier outcome; selecting
an arbitrary entry is not a reliable strategy.

## Why the previous verification missed these paths

Most regressions started with a completed lookup or explicitly constructed a
well-formed partial request. The six successful live checks used clear phrasing
such as “What items are in that order?”. This call reached clarification before
any job, contained misrecognized and streamed number fragments, and used the more
ambiguous items caption. Whole-sentence and warm-session success did not validate
those conditions.

## Audio observations are separate

Capture-overflow observations were all before readiness (20:03:22–24), followed
by the intentional startup-buffer discard. Browser capture begins before the input
pipeline can drain to a ready provider; bounded input buffering accounts for that
startup pattern. No later capture-overflow event appears in the retained log.
It does not establish that the later number continuation was dropped in capture.

Eight playback-starvation observations mean `Playout.take/4` encountered an empty
queue after playing. The counter itself cannot distinguish an audible mid-utterance
gap from another empty-queue transition. The retained data contains no per-event
upstream queue trace or audio recording to attribute all eight to provider timing,
scheduling, or network delivery. No output overflow or failure-driven closure was
recorded. These counters are not the evidence for the clarification defects above.

## Historical diagnosis reproduction

The historical `replay.exs` asserts the defects before this correction; it is not
a passing check of the corrected implementation. Its saved `controls.json` and
`results.json` retain the original findings. It was run from the standalone app:

```sh
cd /Users/humberto/Projects/parlora_consumer
ORDER_DESK_DATABASE=:memory: mix run \
  /Users/humberto/Projects/parlora/validation/clarification-streaming-root-cause/replay.exs
```

For four bounded live classifications, use the normal secure Keychain wrapper:

```sh
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/clarification-streaming-root-cause/replay.exs
```

`controls.json` records successful deterministic assertions. `results.json` retains
the four live calls and their constructed inputs. Neither command starts a live
voice call or changes the saved-order database.

The correction should preserve a bounded unfinished caller request across a
clarification, including number-prefix continuity and known/uncertain operation;
define which pending request owns recovery; and generate questions from the
specific unresolved field (retaining an uncertain candidate for confirmation,
not execution). Add tests with no prior task, streamed continuation after a
clarification, several pending delegations, and the actual ambiguous items wording.
Retain bounded, private input/judgment/decision diagnostics for future live calls
so attribution need not depend on constructed replay. Keep the confidence floor
and explicit page confirmation for writes.

This investigation adds evidence only. It does not change the running application's
behavior or commit the earlier uncommitted fixes.


## Correction implemented

- Retain unfinished caller request text (up to 2,048 bytes) even when the number
  guard runs before classification. Complete only conservatively parsed numeric
  continuations across clarification; never glue a new explicit request or a
  complete replacement ID onto an old prefix.
- Choose one pending recovery owner by clarification/wait revision and documented
  tie-breakers. After creating a first task, recheck remaining delegations so their
  association does not depend on the caller speaking again.
- Retain uncertain operations as confirmation candidates, not known operations.
  Ask a targeted question. A yes to a read-only items question can be classified;
  a no starts no work and may ask what the caller wants instead. An explicit
  correction to delivery status preserves the retained order.
- Keep private bounded attempted-judgment and policy-proposal evidence. The latest
  128 records have a 32 KiB per-record cap, with an omission marker for oversized
  records. Caller text is not exposed by public/dashboard routes. The private
  validation listener has `/__acceptance/interpretations`. Proposal records do
  not prove that Parlora applied the decision; stale revision checks still apply.

`verify_fix.exs` is the current bounded live check. Run it with the same secure
wrapper as above, replacing `replay.exs` with `verify_fix.exs`. `fix-results.json`
records ten passing checks (two rounds): initial numeric continuation to status/123,
repeated full replacement to status/124, confirmation of items/124, correction to
status/124, and rejection with no task started. The final rejection asks what to
check; it is not expected to guess another operation. `first-fix-results.json`
preserves the initial attempt, including uncertain rejection/correction outcomes;
prompt clarification resolved target retention, and rejection assertions now
explicitly allow a safe clarification instead of requiring silence.

The synthetic-session regression begins with no existing task, asks to finish
“Check order one two”, then accepts “three” despite another pending delegation.
It asserts one status/123 job and association of the additional delegation.
Additional tests cover overlapping assistant captions, negative/conflicting IDs,
targeted questions, confirmation changes, bounded evidence and deterministic ownership.

The tests exercise application decisions and live semantic interpretation. They do
not establish microphone recognition or audible quality; another spoken browser
call remains the end-to-end confirmation. The confidence floor and page-only
write authorization were not lowered.

Validation: 121 consumer tests passed on macOS and Linux. The library `mix ci`
passed on macOS (185 ExUnit tests, three excluded live/device tests, native checks,
Credo/ExSlop, ExDNA, Credence and Dialyzer). Core library code was unchanged in this
follow-up; the prior Linux library CI remains applicable.
