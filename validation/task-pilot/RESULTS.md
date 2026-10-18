# OrderDesk task pilot — September 22, 2026

The pilot found and addressed two application interpretation problems. It also
showed why a correct caption score or backend result alone cannot establish a
correct customer experience. The remaining provider and response-quality failures
mean this is **not a production-readiness certification**.

## Baseline: 20 scenarios × 3 attempts

All 60 scheduled attempts ran against GPT-Live-1, TypeSafe jev-1.13.0, the real
browser WebRTC path, AppPolicy, Jido, and separate seeded SQLite databases. Speech
was macOS Samantha at 165 words/minute. Three independent workers ran concurrently.
Backend delay fixtures were 4 seconds for 123 and 1 second for 124/825. Each case
had a 75-second deadline, with a fresh session, database, and interpretation cache.
No microphone, customer database, phone calls, or external messages were used.

The original automated result was **53 passed, 7 failed**. Original outcomes are
retained; rechecks and manual review never replace a failed attempt.

| Baseline cases | Automated outcome |
| --- | --- |
| Cardinal/digit IDs; items; missing/incomplete number recovery; corrections; retries; drafts; save boundaries | 3/3 each |
| Grouped 825; paused 124; status-to-items follow-up | 2/3 each |
| Empty instructions; order not found | 1/3 each |

Review of the seven failures:

- **Four evaluator failures:** correct empty-instructions/not-found results used
  natural wording missed by narrow reply checks. Examples: “I don't see any saved
  delivery instructions” and “order 999 wasn't found here.” Backend actions and
  returned facts were correct. Reply checks now cover the observed variations.
- **Grouped number recognition:** “eight twenty five” became `A25` in one provider
  caption. No lookup was dispatched. OrderDesk asked for the number instead of
  guessing that A meant 8. The provider recognition error is not fixed.
- **Pause/punctuation interaction:** “one hundred twenty … four” became
  `one hundred twenty. Four`. The conservative parser requested clarification and
  dispatched no lookup, avoiding the wrong prefix order 120. This is not fixed by
  indiscriminately removing punctuation. Regression tests verify recovery when
  the caller explicitly repeats 124.
- **Follow-up interpretation defect:** the items lookup for 124 completed, but its
  result was held behind an unnecessary operation clarification. This was fixed.

Review also found two weaknesses among the original automated passes:

- `05-items-124-r2` correctly fetched the desk lamp for 124, but its assistant
  caption included `123... One desk lamp.` That is a response-number mismatch,
  not a wrong backend lookup. It did not recur in three targeted rechecks; its
  provider-side cause remains unproven. Single-order read checks now reject a
  different recognized three-digit ID in the response.
- `08-not-found-r2` passed as soon as the assistant caption reached “I don't see”.
  That is insufficient evidence of a completed not-found answer. The matcher now
  requires the relevant object/fact, and reply checks wait for one second without
  another assistant caption. This is still a bounded caption check, not an
  authoritative speech endpoint or proof of the complete audible response.

Consequently, **53/60 must not be quoted as customer success**, nor should the four
false failures simply be relabeled to claim 57/60. We observed no unintended
backend order selection or unauthorized saved-instruction change. Response quality
had additional problems beyond backend correctness.

## Fix 1: equivalent read actions split the confidence

In `baseline-r3/14-followup-items-r3`, the caller said “What items are in that
order.” The items task was admitted after “What items are in that”; the final
“order” arrived afterward. TypeSafe assigned 61% to `handled_continuation` and 39%
to `items`, with 100% on target 124. Repeated judgments stayed split. Both labels
would associate the same existing read, yet independently applying the 80%
threshold produced uncertainty and blocked delivery.

`Interpretation.interpret_answers/2` now combines support only for an existing
read and its continuation when the target and operation agree. It retains the
80% action threshold, independently checks target confidence, and returns the
existing guarded continuation decision. Raw model probabilities remain in the
private evidence. Different operations/targets, writes, explicit retries, and
clarification replies are not pooled.

A deterministic session regression replays the captured 61/39 split. With the
original independent threshold it receives an unnecessary clarification; with the
fix it receives the desk lamp, settles, claims the late delegation, and retains
exactly two jobs. All three initial live follow-up rechecks passed.

## Fix 2: an already admitted retry lacked explicit provenance

The first fix's broader live rechecks exposed a second issue in two retry trials.
A retry was admitted early after “Please try”. The remaining “checking that order
again” then split between a new `retry_lookup` and `handled_continuation`. The
retry completed and its result was delivered, but the app subsequently asked an
unnecessary question and left interpretation unresolved.

Retry admission now records `retry?: true` in the task input, and interpretation
receives that fact for the active task and recent work. The classifier instructions
explain that words completing this admitted retry are its continuation; a distinct
subsequent retry still starts a new read. We do **not** pool retry probability with
continuation probability: those actions have different effects.

Three fresh TypeSafe evaluations of the captured failing state with this provenance
selected continuation at 99%, with 100% target confidence. Regression coverage
checks that provenance reaches interpretation, a late delegation associates with
the retry, and a later explicit retry remains executable. Live recheck totals are
recorded below and in `results.json`.

## Evaluation changes and remaining limitations

The runnable pilot captures submitted operations/targets, accepted delivery,
clarifications, delegation claims, assistant caption facts, draft states, database
changes, screenshots, and interpretation judgments. Its test-only endpoints bind
to loopback and are not loaded by normal application startup.

The initial 21-case recheck batch had 16 automated passes and 5 failures: one more
valid not-found paraphrase missed by the matcher, the two retry defects described
above, and two voice-approval trials. In one approval trial the entire session
produced no caller or assistant captions, no delegation, and no job despite the
browser reporting readiness and completing the input clip. Its cause is unproven;
it is not evidence that the earlier Pipecat single-caption incident has the same
cause. In the other, the saved database remained unchanged, but the provider failed
to explain browser confirmation after the caller said “save it.” Neither was an
unauthorized write; both are unresolved customer-experience failures.

Separate reply-check rechecks also encountered valid wording absent from earlier
matchers. Every original failure is retained. Current offline tests cover those
observed variants, reject incomplete phrases, and reject unrelated positive facts.
Rule-based matching still needs manual review; it is not a general semantic judge.

An initial smoke attempt spoke during the greeting and got no delegation for a
missing-number request. A bounded greeting wait allowed the next smoke to complete;
this changed a test precondition, not production behavior. It does not establish
that interrupting the greeting is reliable.

The first baseline disconnected as soon as reply keywords matched, so some
captions are truncated. Draft/refusal/save tests primarily verify application and
stored state, not every spoken acknowledgment. No human/acoustic playback audit,
accent coverage, noise coverage, production traffic, or statistically reliable
success-rate estimate is claimed. Pipecat remains the separate caption benchmark;
these synthetic OrderDesk utterances add explicit task outcome labels.

## Reproduce and inspect

See [README.md](README.md) for commands. Compact outcome counts, evidence hashes,
and an immutable-attempt inventory are in [results.json](results.json). Full local
artifacts are in ignored `runs/`, including `baseline-analysis/review.json` for the
baseline dialogue audit. No raw audio or SQLite database is added to source control.

## Final validation

- **149 OrderDesk tests passed**, including the captured confidence-split session
  regression, conservative number recovery, and retry-provenance coverage. The
  later explicit-retry assertion was also rerun successfully (6 tests in that file).
- **8 Node checks passed** for the pilot and existing acceptance runner; formatting
  and diff checks passed.
- **9/9 final live targeted cases passed:** status-to-items follow-up, explicit
  retry, and spoken approval, each repeated three times with both application fixes.
  The approval passes do not establish a fix for the earlier provider failures.
- All **105 attempts** are retained: 60 baseline, 3 smoke, and 42 targeted rechecks.
  This is a heterogeneous inventory, not a pooled success-rate sample. Every
  completed worker reported zero active sessions at cleanup.
- Three response-ID rechecks passed; the wrong assistant-caption ID did not recur.
  The current reply matcher accepts every observed complete empty/not-found
  response and rejects the incomplete baseline “I don't see” fragment in an offline
  audit. This does not retroactively change any stored outcome.

The useful gain is a runnable task-level evaluation, two concrete interpretation
fixes, and regression protection. It also leaves explicit evidence of what still
needs work; a larger real-voice evaluation should not assume those failures are gone.

## Subsequent silent-session investigation

The follow-up [investigation](../silent-session/README.md) found an unbounded
provider-command acknowledgment wait and added a configurable failure/reconnect
path plus opt-in transport diagnostics. Two local browser fault/recovery checks and
six new instrumented live trials passed. The original upstream cause remains
unproven; these results do not alter any outcome above.


## Browser release baseline

The subsequent [release check](../release/RESULTS.md) uses stronger response
assertions and adds a reconnect scenario. Its fixed 21-attempt batch had 18 passes
and three retained failures: two interpretation-timeout cases with no backend work
and one answer that did not explicitly state the expected delivery status. This
is a separate baseline and does not change the pilot outcomes above.
