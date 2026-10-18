# Unnecessary clarification diagnosis — September 17, 2026

**Follow-up:** fixes and verification are recorded in [FIX-RESULTS.md](FIX-RESULTS.md).
The diagnosis and failure reproduction below describe the code before those fixes.

Investigates the two partial results in [the first-four-case run](../first-four-cases/README.md).
No runtime implementation was changed during diagnosis. Evidence combines traced browser replays,
direct live TypeSafe probes, a running-session reproduction, and source inspection.

## 1. Fresh order lookup: overlapping intent choices fail the confidence gate

`OrderDesk.Interpretation.evaluate/1` always offers `followup` alongside `status`,
including when `active_task=nil` and `recent_work=[]`. The status description
mentions delivery/tracking facts, refreshes, and corrections, but does not explicitly
establish that a bare “Check order 124” is the demo's default status request.
The prompt says follow-up concerns previous work; the choice set does not enforce
that prerequisite. The live classifier still assigns probability to follow-up.

In the traced browser replay of “Check order one hundred twenty four”:

- Input contained the complete utterance and candidate `124`, with no active/recent work.
- TypeSafe selected `status` with probability **0.75**, `followup` **0.22**;
  target `124` had probability **0.99**.
- `interpret_answers/1` requires each selected answer's probability to be at least
  **0.80**, so it returned an uncertain *intent*, not an uncertain order.
- A later evaluation returned status **0.81**, allowing this replay to recover.

The next browser call reproduced the actual unnecessary question on its initial
“Check order one hundred twenty-three”: status probabilities **0.79, 0.79, 0.78**
remained below the threshold, while the target was **0.97**. Recovery eventually
asked what to check rather than starting the lookup. The same mechanism therefore
appears with both demo order numbers. It is not missing-number extraction or a
backend failure: the initial job is never admitted.

The original failed order-124 run did not retain its raw probabilities. The numbers
above belong to diagnostic replays, not a reconstructed claim about that run.

## 2. Completed correction: insignificant caller tails reopen interpretation

`AppPolicy.interpret/3` skips classification only when the latest caller fragment's
`arrival_order` exactly matches the active task's `input.user_revision`. A later
fragment, even punctuation or whitespace, breaks that equality. `latest_input/2`
then passes that fragment as `new_caller_text` to TypeSafe. The input is not checked
for a meaningful change before classification.

Every uncertain judgment is routed through `Recovery.decide/2`, including an
uncertain `none` judgment on a completed task with no pending delegation. After
the 1,500 ms settle delay and 600 ms verification delay, continued uncertainty
produces a question about an already completed request. Accepted result delivery
does not prevent this new, task-targeted clarification; the session becomes
unresolved while the existing job remains completed/accepted.

The running-session reproduction used the real AppPolicy, TypeSafe, Jido backend,
and a scripted provider with synthetic local audio:

1. Submitted a complete correction history ending at order 123.
2. Received the correct result, with interpretation `settled`.
3. Sent one additional caller transcript fragment: **`.`**.
4. TypeSafe selected `none` with probabilities **0.58, 0.54, 0.56**; target 123
   remained high-confidence. The application treated this as business ambiguity.
5. Received “For order 123, are you asking about the earlier lookup, delivery
   status, items, delivery instructions, or rejecting a draft?”
6. Observed interpretation `unresolved`; the single job remained
   `completed` with delivery `accepted`.

Direct classifier probes also produced uncertain intent for a trailing space or
empty new text. A final meaningful word (`three`) was correctly recognized in that
probe; this diagnosis does not justify ignoring all continuations or new requests.

The original case-1 events establish clarification *after* the third result was
accepted and subsequent unresolved state. They lack raw transcript fragments and
classifier input, so the exact original tail cannot be recovered. The punctuation
reproduction proves the failure mechanism; it does not prove the original tail was
a period. The diagnostic browser correction replay itself finished successfully,
after encountering the separate initial-lookup problem above.

## Additional observability defect

`Parlora.Session.apply_policy/2` sets `context_resolved?` based on wait/clarification
decisions only when their `task_id` is a binary. Decisions targeting a pending
delegation have no task ID, so a session can display `settled` despite an outstanding
delegation clarification. The original case-3 intermediate status demonstrates
exactly this: no jobs, one pending delegation with clarification, and `settled`.
This did not cause the bad classification; it hid its unresolved state.

## Fix direction

- Define the default meaning of a fresh “check order” request and restrict follow-up
  choices to state that contains relevant previous work. Validate against actual
  model outputs; merely lengthening the recovery delay will not fix this overlap.
- Track meaningful handled caller input so punctuation/whitespace does not reopen
  a completed request. Preserve interpretation of real corrections and ambiguous
  new targets. Do not globally ignore low-confidence judgments or lower the threshold.
- Include delegation-targeted waits/questions in the public interpretation status.
- Add regressions at both the policy/session level and the live classifier boundary.
  Existing tests predominantly stub semantic judgments, so they cannot detect the
  observed probability split. The existing continuation regression covers a refusal
  tail with a supplied correct judgment, not a no-op tail with real model uncertainty.

## Evidence and reproduction

- [Browser classification inputs, probabilities, decisions](browser-classification-trace.json).
- [Browser captions and work status](browser-replays.json).
- [Completed-tail full trace](completed-tail-trace.jsonl) and [final status](completed-tail-status.json).
- [Direct trailing-fragment classification probes](tail-classification-probes.jsonl).
- [Running-session reproduction script](completed_tail_replay.exs).

To rerun the session reproduction from the standalone consumer, using the pinned
toolchain and existing secure credential helper:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=/tmp/parlora-tail-replay.sqlite3 \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/recorded-browser/clarification-root-cause/completed_tail_replay.exs
```

This uses live TypeSafe requests, but a scripted provider instead of a live GPT-Live
call. It records only policy inputs/decisions and classifier answers, never keys.
Its trace file is `/tmp/parlora-completed-tail.jsonl`. Model outcomes can vary;
the committed trace records the observed failure without requiring a rerun.

Browser diagnosis used an isolated database and loopback port 4002 with the same
eight-second order-124 backend delay as the earlier tests. All calls were closed,
original WAV fixtures restored, and `/health` reported zero active sessions.
Neither acoustic quality nor new Linux behavior was evaluated.
