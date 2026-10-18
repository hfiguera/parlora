# Unnecessary items clarification — 13:47 call, September 21

## What the original call establishes

`call-evidence.json` preserves the visible transcript and diagnostics. Order 124's
status result was accepted at 13:47:42. The caller then asked “Do you check it”,
received its status, and asked “Do you know what items are there”. Context waits
began at 13:48:07; application clarification was requested at 13:48:10. The
assistant asked whether this meant the same order 124. Only after “Yes” did the
items job start, at 13:48:16; its result was accepted at 13:48:17.

This is different from the earlier trailing-word failure: here the items job had
**not started before clarification**. It is not a slow backend or lost audio job.

The original per-fragment timestamps and TypeSafe judgments are not available
through this server's diagnostic interface. Its bounded private in-memory evidence
has no retrieval route and the VM has no distributed node name. We did not restart
or modify the server to extract it. The following reproduction uses constructed
snapshots based on the visible wording, not the original wire events or scores.

## Two reproducible interpretation problems

### 1. Handled progress remains in the fresh-input window

`AppPolicy.latest_input/2` uses the latest task's `input.user_revision` as its
cutoff. The `followup` decision associates a delegation or returns no actions; it
does not record a separate consumed-input position. Thus answering “Do you check
it” does not advance that window. When the next items question arrives,
`new_caller_text` can still be:

```
Do you check it
Do you know what items are there
```

The classifier has the correct latest segment and current order, but its principal
fresh-input field includes both an already answered progress request and a new
items request. That introduces competition with `lookup_progress`.

### 2. The new continuation choice is too broadly offered

Commit `fd1927b` added `handled_continuation` to fix sentence tails arriving after
an early task admission. `Interpretation.intent_choices/1` offers it whenever the
active task is any status/items/instructions lookup and no clarification is
outstanding. The choice description is generic: it does not name the actual
operation already handled. Even after excluding the old progress question, the
classifier splits its score between a new `items` request and continuation of
an earlier **status** request.

This is a reproducible adverse effect of the recent continuation interpretation
change. The later greeting and audio-recovery changes did not alter this path.
It does not establish that the original call had exactly these scores.

## Controlled live TypeSafe results

Twelve bounded read-only classifications used the current `jev-1.13.0` model and
application prompts. Every variant ran twice. No GPT-Live call or database write
was made. The 0.8 acceptance threshold was unchanged.

| Constructed input / choice control | Items score, two runs | Decision |
| --- | --- | --- |
| Old progress + items; production choices | .35 / .43 | Clarify |
| Only fresh items; production choices | .57 / .58 | Clarify |
| Remove progress from history too; production choices | .58 / .62 | Clarify |
| Old progress + items; remove continuation choice | .60 / .57 | Clarify |
| Only fresh items; remove continuation choice | .94 / .93 | Start items lookup |
| Only fresh items; describe continuation as finishing STATUS, not a new ITEMS request | .98 / .98 | Start items lookup |

The target was **124 in every case**, with scores .96–.99. In production-choice
controls, the failing field is intent, not order identification. Scores are model
outputs, not calibrated probabilities of correctness.

The input-window control advances the synthetic task's user revision solely to
isolate the classifier field; changing business task revisions is **not** the
proposed implementation. Full history and the same active task description remain
available in the fresh-items controls. The no-progress variant is an additional
control, not a suggestion to discard conversation history.

## Why this becomes an order-confirmation question

`Interpretation.interpret_answers/1` rejects any required field below .8.
`AppPolicy.clarify/4` retains the high-confidence order and proposed items operation.
After the settle/verification phases, `Clarification.question/1` produces:

> Do you mean the items for order 124?

That combines operation and order into one question. The original spoken
confirmation emphasizes the order. The exact provider wording cannot be
reconstructed, but the replay generates the same kind of redundant clarification
while still correctly knowing 124. Recovery timers reclassify the conflicting
input; elapsed time does not repair its semantics.

## Correction direction

The fix belongs in OrderDesk's application-owned interpretation:

- Track handled conversational input independently of the last business task, or
  otherwise exclude answered progress from the next request without discarding
  history or treating every assistant backchannel as a completed user turn.
- Restrict/describe continuations against the actual handled request and operation.
  Preserve the earlier genuine split-sentence regression, plus operation changes,
  corrections, refusals, and outstanding clarification replies.
- Preserve the confidence threshold. When uncertainty really concerns operation,
  ask about that operation without making a known order appear missing.

These controls establish a correction direction, not a validated production fix.
No runtime/application code, server process, or saved order data was changed.

## Reproduction

From `examples/order_desk`, offline verification uses the retained responses:

```sh
ORDER_DESK_DATABASE=:memory: ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
  mix run ../../validation/browser-items-20260921/replay.exs --cached
ORDER_DESK_DATABASE=:memory: ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
  mix run ../../validation/browser-items-20260921/replay.exs --ablation --cached
```

The replay asserts matching inputs, the known target and the policy decision for
all 12 responses. `results.json` and `ablation-results.json` retain full classifier
inputs and answers. For fresh read-only judgments, omit `--cached` and use the
normal Keychain wrapper with `ORDER_DESK_TYPESAFE=1`; model output may vary.

## Implemented correction

The application now supplies bounded `recent_dialogue` alongside caller history:
eight speaker runs, each retaining at most 512 characters. It includes assistant
responses so the classifier can distinguish the answered progress question from
the latest items request. The prompt explicitly defines `new_caller_text` as
**since task admission**, not a list of unhandled requests. It preserves full
bounded caller history and handled-input context for pronouns, partial numbers
and backchannels. No business task revision is advanced to fake consumption of
a progress question, and policy execution does not mutate separate cursor state.

Continuation choices now describe the actual handled operation/order and explicitly
exclude new operations. Assistant dialogue is untrusted conversational context,
not authorization or evidence of a database fact or save. The .8 confidence floor,
recovery deadlines and existing guards remain unchanged.

### Verification

`verify_fix.exs` uses the three original input-window variants against the changed
production policy and prompt, twice each. **All six** live TypeSafe judgments
selected items/124 above threshold (items score 1.0 in these runs) and started the
items job without clarification. `fix-results.json` retains the inputs and answers.
These are model scores, not an accuracy guarantee.

`verify_continuation.exs` reruns the earlier seven semantic controls twice with the
new prompt, retaining `continuation-fix-results.json`. **All 14 continuation guards
passed**: true split-sentence tails settled, new status operations dispatched, and
draft requests retained their settling step. As in the earlier baseline, eight
negative-control responses for changed/missing orders, ambiguous intent and cancel
remained below threshold and asked for clarification. They were not silently
ignored as continuations. This is 6 exact semantic matches plus 8 conservative
clarifications, not 14 ideal conversations or proof that every follow-up works.

The initial diagnostic `replay.exs` and retained pre-fix responses describe the old
classifier input shape. Its cached input-equality check intentionally detects the
new dialogue field. For the current implementation use these offline checks from
`examples/order_desk` instead:

```sh
ORDER_DESK_DATABASE=:memory: ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
  mix run ../../validation/browser-items-20260921/verify_fix.exs --cached
ORDER_DESK_DATABASE=:memory: ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
  mix run ../../validation/browser-items-20260921/verify_continuation.exs --cached
```

New ExUnit checks cover bounded dialogue, interleaved backchannels, and a real
Parlora/ScriptedProvider session that answers progress then starts exactly one
items job, associates a late delegation and requests no clarification. Existing
correction, refusal, draft and clarification tests remain enabled.

Full application format/compile checks and **136 ExUnit tests passed** on each
of macOS and Linux with the pinned toolchain; see `macos-tests.log` and
`linux-tests.log`. Both current cached verification scripts also passed.
The idle localhost:4000 server was restarted with the changed application and
its existing SQLite data preserved. No new end-to-end human voice call is claimed
for this correction; live classification probes and deterministic session tests
are the available evidence.
