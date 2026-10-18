# Interruption clarification investigation — September 17, 2026

Follow-up: [implemented fix and verification](FIX-RESULTS.md).

## Finding

Reproduced an application interpretation defect that explains the unnecessary
order-number question: an unfinished spoken number can start a task, and the
remaining word is then interpreted against that premature task. This is still
possible at `d82e1dc`.

1. `Speech.numbers/1` extracts `120` from “one hundred twenty”, even when “four”
   will follow. The policy interprets streaming fragments while an existing task
   is active; it need not wait for the next delegation.
2. A sufficiently confident judgment immediately supersedes the task with order
   120. There is no admission delay for a potentially unfinished numeric phrase.
3. Starting that task advances `input.user_revision`. When “four” arrives, the
   classifier receives `new_caller_text: " four"`, a handled prefix ending in
   “twenty”, and active/recent work for 120. The complete caller history correctly
   contains 124, and 124 is among the candidates. Nevertheless, the live classifier
   favors 120 with insufficient confidence instead of resolving the completed 124.
4. Recovery waits 1,500 ms, then verifies after another 600 ms with a fresh
   classifier request. The same fragmented state remains uncertain. The policy
   submits “Please clarify the request and say the three-digit order number” and
   leaves the second delegation pending.

The mechanism is premature task admission plus ineffective interpretation of the
remaining number fragment. Longer clarification waits alone do not repair the
state: the complete text is already present. Lowering the confidence threshold
would risk accepting the wrong order. A fix should stabilize numeric input before
admission and keep an unfinished caller request coherent across task creation.

## Evidence and confidence

### Original call: consistent, but incompletely instrumented

The [original events](../remaining-cases/interruption-first-events.txt) show a
second job starting and completing within about 0.4 ms, followed by clarification
and a pending second delegation. The test had an eight-second delay for order
124. That strongly suggests the second job did not target 124, but these events
do not retain task inputs or classifier probabilities. We cannot prove that its
intermediate target was specifically 120, or recover the exact triggering delta.
The original captions do contain the complete 124 request.

### Controlled session replay: failure reproduced on current code

[sequence_replay.exs](sequence_replay.exs) uses the real application policy,
live TypeSafe, Jido, synthetic local audio, and the scripted provider. It sends:

1. “What items are in order one hundred twenty three”; await its result.
2. “Wait, what items are in order one hundred twenty”; await the admitted result.
3. “ four”, then the second delegation; observe for five seconds.

Observed results:

- First result: order 123 contains a travel mug and two coffee beans.
- Premature result: order 120 was not found.
- Complete 124 history and candidate present on every subsequent classification.
- Recovery submits the unnecessary number question after its fresh recheck.
- Final interpretation: unresolved; second delegation pending.

See [trace](sequence-trace.json) and [final status](sequence-status.json).
This deliberately controls fragment timing; it proves a real failure path, not
the exact transcript timing of the historical call. It does not exercise audio
interruption or disconnection.

### Classifier boundary probes

[classifier_probe.exs](classifier_probe.exs) compares the original prompt from
`b354c8b` with the current prompt. Both correctly interpret the complete correction
when active work is still 123. Both accept the partial 120 phrase. After work has
advanced to 120, both return an uncertain judgment for the remaining “four”, even
with full 124 history. [Recorded probabilities](classifier-results.json).

Two additional diagnostic states test punctuation and a newline splitting the
number. These are hypothetical controls, not observed original-call fragments.
The current policy bypasses punctuation-only reclassification following the prior
fix; directly calling the classifier bypasses that guard. A split-number newline
is not necessary to reproduce this defect.

### Current live browser replay: passed with different fragment timing

On a separate isolated server at `127.0.0.1:4002`, the browser sent the original
items clip and then the interruption clip as the assistant caption reached
“Okay,” with its audio element playing. The complete 124 correction arrived
before another task was admitted: only 123 and 124 were looked up. The assistant
answered “Order 124 has one desk lamp”; both delegations were claimed and
interpretation settled. See [browser evidence](browser-replay.json) and
[policy/classifier trace](browser-trace.json).

This successful timing does not disprove the controlled failure. Playback-element
and caption evidence are not a human acoustic assessment. A preliminary call sent
the correction before a distinct response to the first request and was closed;
it is excluded from the saved browser trace because it did not match the intended
interruption timing.

## Reproduce

From the standalone consumer, with the pinned toolchain and existing secure
Keychain helper:

```sh
ORDER_DESK_TYPESAFE=1 \
ORDER_DESK_DATABASE=/tmp/parlora-interruption-probes.sqlite3 \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run \
  ../parlora/validation/recorded-browser/interruption-root-cause/sequence_replay.exs
```

Run `classifier_probe.exs` the same way for the prompt comparison. These are
bounded live diagnostic probes, not deterministic offline regression tests; model
judgments can vary. Outputs go to named `/tmp/parlora-interruption-*` files. The
first classifier probe completed its requests but failed to serialize answer
structs; the serializer was corrected and the recorded run completed successfully.

No production code changed. The normal app/database and recorded clips were left
unchanged; calls were disconnected, the diagnostic server stopped, and the browser
returned to the existing isolated app on port 4001. Disconnect/reconnect behavior
was not retested because the finding precedes disconnection.
