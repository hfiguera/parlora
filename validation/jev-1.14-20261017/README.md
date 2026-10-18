# JEV 1.14.0 evaluation — October 17, 2026

**Decision: retain pinned `jev-1.13.0`.** The candidate is compatible with our
existing `typesafe_ai` 0.1.0 client, but it introduced unnecessary clarification
in cases where the baseline admitted the correct request. No application model,
prompt, confidence threshold, save authorization, or running server was changed.

This records the pre-fix model evaluation at `7e0c409`. The subsequent
[speech-act arbitration fix and regression evidence](../speech-act-fix-20261017/README.md)
repair the captured auxiliary-answer conflict while retaining the model pin.

TypeSafe documents both pinned IDs on the same API endpoint. The candidate is
currently behind `jev-preview`, while `jev-latest` points to 1.13.0.
[Official model reference](https://docs.typesafe.ai/models),
[release announcement](https://typesafe.ai/blog/jev-1-14).

## Method and retained evidence

The existing 18 semantic dialogues were extended with real regression shapes:
new requests, operation changes after completed work, read suffixes across
assistant speech, retry suffixes, explicit order corrections, incomplete numbers,
conflicting numbers, and replies to pending clarifications. Expectations were set
before submitting each case. All calls used the actual `Interpretation.questions/1`,
`interpret_answers/2`, and `AppPolicy.interpret/3` from source revision `7e0c409`.

Each case was evaluated sequentially against both pinned IDs, three times, with
the normal 2-second client deadline, no retries, no interpretation cache, and the
unchanged 0.8 confidence gate. The report checks admitted work's operation and
order for the new regression cases; continuations must associate existing work
without starting another lookup. Ambiguous or incomplete requests must clarify.
Requests with deterministic policy handling record no model response and are
counted separately from actual API calls. Every actual response matched its
requested pinned model version. No voice provider or backend was called and no
order edits were executed. Only synthetic dialogue text was submitted.

| Run | Cases × repetitions per model | 1.13 policy matches | 1.14 policy matches | Live API calls per model |
| --- | --- | --- | --- | --- |
| [Initial](results/initial-comparison.json) | 41 × 3 | 118/123 | 117/123 | 114 |
| [Expanded](results/comparison.json) | 43 × 3 | 125/129 | 122/129 | 120 |

The expanded run adds an already admitted retry suffix and a completed numeric
prefix correction. Both runs remain available; the second does not replace
failures from the first. There were nine deterministic policy bypasses per model
in each run. These counts are policy matches on a small fixed synthetic corpus,
not estimates of model accuracy or production call success rates.

## Why migration is held

The expanded run exposed two regressions in the requested areas:

- **A new operation after an order clarification:** the active old status lookup
  concerns 124, but the retained question explicitly concerns order 123. The
  caller answers “What items are in that order?” The baseline starts items for
  123 on all three attempts. The candidate chooses the correct target and intent
  label but gives items only about 0.75 confidence, below 0.8, and asks the caller
  to confirm the operation again on all three attempts.
- **Delayed numeric correction:** an admitted status request for 120 receives
  the trailing word “three” after assistant speech. Both versions identify 123.
  The candidate's replacement confidence remains below 0.8 on all three attempts;
  the baseline admits the corrected status lookup on two of three attempts.
  The candidate therefore adds two clarification outcomes relative to the baseline.

The candidate also adds clarification for “Yes, save it” after the draft review
prompt: four of six attempts across the two runs, versus none for the baseline.
Neither version authorizes a save. In the first run, `none` confidence falls from
0.85–0.87 for the baseline to 0.74–0.76 for the candidate. A model upgrade should
not introduce these redundant questions. Lowering the confidence threshold to
make the candidate pass would change safeguards and was not attempted.

There are improvements too: the candidate passed two running-items continuation
attempts that the baseline missed in the initial run, and three progress-question
attempts that the baseline missed in the expanded run. Those gains do not cancel
regressions in previously working request/correction cases.

Both versions can still fail a completed “Do you know what items are” + “there”
continuation. In the initial run, both returned continuation confidence of about
1.0 and the correct target, but a low-confidence `speech_act: presence` override
made the application ask a new question. The expanded run passed those same
structured states. This is evidence of an existing interpretation conflict and
run-to-run variability, not proof that a version switch fixes it. The original
human call's model answers were not retained, so this does not establish its
exact triggering scores.

### Speech-act root cause confirmed by frozen-answer replay

The failure is in OrderDesk's arbitration of the typed answers, triggered by an
uncertain auxiliary model prediction. In the first completed-items observation,
1.13 returned `handled_continuation` at selected probability 1.0 and target 825 at
0.99, while `speech_act` selected `presence` at only 0.55. The corresponding 1.14
observation returned continuation 1.0, target 825 at 1.0, and presence at 0.46.
These are selected-option probabilities used by our gate, not the API's separate
normalized `confidence` statistic.

`Interpretation.interpret_answers/2` matches the special speech-act **label before
validating its probability**. It replaces the confident business intent with
`presence`, stops requiring the original intent/target, and replaces the known
order with `unknown`. It then rejects the speech-act answer against 0.8 and
returns uncertainty for the entire interpretation. Clarification consequently
receives neither the admitted operation nor its order and asks for both again.
The low-confidence special act is never accepted as a valid final judgment;
the defect is letting it first override and then veto otherwise valid work.

[Eighteen offline causal replays](results/speech-act-replay.json), using all six
captured completed-items responses, verified the chain with the real policy:

- Unchanged captured answers: `presence` / unknown order / clarification.
- Omit only the auxiliary answer: continuation / 825 / associate existing work.
- Locally permute the auxiliary answer to equally uncertain `other`, retaining
  its top probability: continuation / 825 / associate existing work.

The latter two are explicit counterfactuals, not new service observations. They
leave the primary intent, target, context, and thresholds unchanged. No API calls
or production code changes were needed. Reproduce with `speech_act_replay.exs`,
passing absolute paths to `results/initial-comparison.json` and a new output JSON.
That historical diagnostic expects the pre-fix behavior and requires a consumer
built at `7e0c409`. Use the current semantic report's `--replay` option to verify
the fixed behavior against the same saved answers.

The main intent question explicitly recognizes the "items are" / "there" read
continuation. The auxiliary question emphasizes fresh speech acts and its `other`
description lists new business requests without explicitly covering read tails.
That taxonomy gap is a plausible contributor to the model ambiguity; replay alone
does not prove the model's internal reason for selecting presence. TypeSafe's
[fan-out guidance](https://docs.typesafe.ai/patterns/fan-out) makes the application
responsible for deciding which parallel answers are relevant.

The appropriate fix is application-side confidence/relevance arbitration and
aligned question semantics, preserving genuine presence checks and the existing
guards for new requests, corrections, drafts, and clarification replies. Merely
changing JEV versions or lowering the threshold does not repair this causal path.

## Other shared model use and offline checks

All [38 existing contextual clarification fixtures](../gemini/jev-clarification/contextual-cases.json)
were compared separately with the real clarification questions, 700 ms deadline,
0.85 confidence gate, and no retries. See [coverage results](results/coverage.json).
The baseline matched 22/38 fixture outcomes and the candidate 27/38. Neither
produced a confident incorrect suppression. Most unmatched outcomes were
conservative uncertainty; these figures describe the model judgment, not the
application's complete fallback behavior. Improvement was not uniform across cases.

The [offline suite](results/offline-tests.log) passed **225 tests** against the
packaged consumer. Application and dependency code remain unchanged. Ordinary
tests are deterministic; they do not prove a hosted model's behavior. The live
semantic command intentionally exits with failure when a migration case fails.
The comparison used 468 live semantic requests across both runs and 76 coverage
requests, with no automatic retries. [Summary and source hashes](results/summary.json).

## Reproduction

From a consumer materialized with `scripts/consumer.sh`, using the normal
development Keychain helper and a separate evaluation database:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=/tmp/order-desk-jev-check.sqlite3 \
  python3 scripts/with_keychain.py mix run scripts/semantic_judgment_report.exs \
  /tmp/parlora-jev-comparison.json --models jev-1.13.0,jev-1.14.0 --repeats 3
```

The coverage runner accepts absolute paths to the existing fixture file and a
new output report:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=/tmp/order-desk-jev-coverage.sqlite3 \
  python3 scripts/with_keychain.py mix run \
  /ABSOLUTE/PARLORA/validation/jev-1.14-20261017/coverage.exs \
  /ABSOLUTE/PARLORA/validation/gemini/jev-clarification/contextual-cases.json \
  /tmp/parlora-jev-coverage.json
```

Reconsider migration after the retained cases meet their policy expectations with
the original confidence gates, including repeated runs rather than a selected
successful attempt. Fixes to the existing speech-act conflict should be evaluated
against both models independently of the version choice.
