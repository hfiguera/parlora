# Root causes of the three live acceptance failures

Investigated against unchanged production code at `1f1d1fb` on 2026-09-21.
Five controlled policy replays, a number-parsing comparison, a complete session
control, and three bounded live TypeSafe judgments support the findings below.
No telephone call or routing change was needed for this investigation.

## 1. Browser: the correct number is excluded before classification

The saved clarification input contains this exact request:

```text
 For order one hundred twenty
 four, change the delivery instructions to leave it at reception
```

`CallerHistory.text/1` inserts a newline when an intervening assistant fragment
separates caller fragments. Its conservative fallback also separates fragments
when timing information is unavailable. A conversational pause is consequently
treated as a hard boundary for number parsing.

`Speech.numbers/1` intentionally excludes newlines from number separators.
For this recorded text it returns only `["120"]`; changing the separator to a
space in the controlled comparison returns `["124"]`. With no active task or
retained known order, `AppPolicy` therefore offers the target classifier only
`120` and `unknown`. **124 cannot be selected**, however clearly the model
understands the intended request. The live replay chose delivery with probability
1.0 and unknown target with probability 0.68; it emitted the same clarification.

Existing continuation logic does not repair this shape: before the first task
there is no handled task prefix to reconstruct, and `continue_number/2` accepts
only a number-only suffix, not “four, change the delivery instructions…”.
The earlier hypothesis that a clarification-time continuation caused this
specific failure was too narrow: the candidate was already lost before the
first clarification.

Relevant code: `examples/order_desk/lib/order_desk/caller_history.ex:22`,
`speech.ex:15`, `speech.ex:90`, `speech.ex:108`, `app_policy.ex:102` and
`app_policy.ex:331`.

**Fix direction:** reconstruct an unfinished number within its request across
these fragment boundaries, including a suffix followed by operation text.
Preserve actual separate requests; globally removing newlines would incorrectly
combine unrelated numbers. Add this exact split as a regression case.

## 2. Twilio: a continuation reopens an already handled refusal

The stored refusal task was admitted at caller revision 41. A later clarification
contains `request_text: " instructions"`, `known_order: "124"`, missing
operation, and `candidate_operation: "refuse"`. Its context-wait key is
`47:verify`. The refusal job's result is nevertheless `accepted`.

The causal path is:

1. `latest_input/2` slices caller input at task admission, even if the caller is
   still finishing the same sentence.
2. `handled_input/2` keeps only the final segment before that revision.
   Interleaved assistant fragments can fragment that context further.
   The suffix “instructions” is presented as fresh input; only number
   continuations receive deterministic reconstruction.
3. The classifier's uncertain intent is routed through the generic clarification
   path, even when its candidate operation matches the already executed refusal.
   The 0.8 threshold is working as configured; the input/lifecycle handling is
   the weakness. A delay does not reassemble the consumed request.
4. After settle and fresh verification, `Recovery.decide/3` requests clarification
   on the completed task. The session then reports unresolved despite its
   accepted result. `awaiting_reply?/1` holds that clarification until fresh
   caller input arrives.

The controlled replay injects the uncertainty evidenced by the saved marker and
reproduces the exact question: “Do you mean refusing a delivery draft for order
124?” A confident refusal judgment instead returns no action and stays settled.

**Evidence limit:** the original acceptance harness did not export the private
classification trace, including exact probabilities and timed snapshots. The
synthetic replay reconstructs the observed fragments, not those missing exact
timestamps. A fresh live classification with the correctly seeded rejected draft
returned refusal at 0.85 confidence and did not clarify. Thus the policy failure
path is reproducible, but the original model uncertainty is not claimed to be a
deterministic model bug or exactly replayed.

Relevant code: `app_policy.ex:320`, `app_policy.ex:331`, `app_policy.ex:381`,
`interpretation.ex:243`, `recovery.ex:99`, and
`lib/parlora/session.ex:659`.

**Fix direction:** retain the full request associated with a task and distinguish
a continuation from a new request before reopening interpretation. Preserve
uncertainty for genuinely new or conflicting requests; do not solve this by
lowering confidence thresholds or ignoring all speech after refusal. Add a
regression with the entire “No, don't save that. Keep the original instructions”
sentence split around assistant fragments, including an uncertain-tail control.

### Correction: the draft really was rejected

The previous assessment used the older pending-draft semantics. Current
`OrderDesk.Lookup` invokes `Store.refuse/3`; the refusal test explicitly expects
rejection. The retained SQLite database confirms one rejected draft and zero
saved instruction changes. The assistant's rejection announcement was correct.
See [database evidence](twilio-database.json).

## 3. Telnyx: a new operation silently requires a new delegation

The recorded session has only the original claimed status delegation. The
follow-up was transcribed, but no second delegation reached the session and no
items job started.

`AppPolicy.decisions/7` can supersede the current task for the same operation,
but a different operation requires `pending`. With completed `status`, new
`items`, and no pending delegation, it falls through to `[]` at
`app_policy.ex:244`. This happens **even with a confident, correct classification**.

`Session.apply_policy/2` treats the empty decision list as resolved; `Progress`
reports settled when no pending delegation remains. The application has neither
started work nor represented waiting for the missing delegation. There is no
timer or recovery action to cause progress if the caller stays silent.

Controls:

- Identical items judgment without a pending delegation → `{:ok, []}`.
- Add only a pending delegation → `:start_task` for items/124.
- Real supervised session with scripted provider: one accepted status job,
  recognized items intent, **one job and settled** without delegation. Injecting
  the missing delegation produces **two jobs, both accepted**.
- Live TypeSafe replay: items probability 1.0, target 124 probability 0.99;
  policy still returns `[]`.

Relevant code: `app_policy.ex:217`, `lib/parlora/session/decisions.ex:128`,
`lib/parlora/session.ex:659`, `lib/parlora/session/progress.ex:140`.

**Evidence limit:** no second delegation was observed at the session boundary.
The retained artifacts do not include raw provider wire events, so they cannot
prove why the upstream delegation was absent or distinguish model omission from
an earlier adapter issue. The application admission/recovery gap is confirmed
independently and is sufficient to reproduce the stall.

**Fix direction:** make admission of a recognized new operation explicit. Either
support starting application-recognized work through a defined interface, or
represent bounded waiting/recovery for provider delegation. Do not invent a
provider delegation ID, silently mark the request settled, or weaken the test.
Account for a real delegation arriving late to avoid duplicate jobs.

## Why existing deterministic acceptance passed

The existing acceptance helper supplies a delegation for the items request.
The earlier refusal-continuation test injects a confident classifier answer for
its particular trailing fragment. Number tests cover contiguous and overlapping
fragments, while explicitly preventing arbitrary combination across newlines.
Those are useful controls, but they do not cover these three failure shapes.

## Reproduction and artifacts

From the standalone consumer with `ORDER_DESK_DATABASE=:memory:` and the pinned
Elixir/Erlang/Rust environment:

```sh
mix run /Users/humberto/Projects/parlora/validation/regression-20260921/root-causes/policy_replay.exs
mix run /Users/humberto/Projects/parlora/validation/regression-20260921/root-causes/session_replay.exs
```

For the three optional live classifier judgments, use the existing secure wrapper:

```sh
DIAGNOSE_LIVE_CLASSIFIER=1 ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/regression-20260921/root-causes/policy_replay.exs
```

The replay does not make phone calls or open a real microphone. It uses synthetic
session audio and in-memory database state. See [policy replay](policy-replay.log),
[live judgments](live-judgments.json), and [session control](session-replay.log).
No production code, confidence threshold, or acceptance assertion was changed.
