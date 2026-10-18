# Post-fix JEV 1.14.0 revalidation — October 17, 2026

**Decision: retain pinned `jev-1.13.0`.** Revalidation was worthwhile after fixing
the application-side speech-act conflict. That case now passes on both versions,
but 1.14 still adds unnecessary clarification for a clear operation reply and
delayed order-number corrections under the current questions and confidence gates.

The application, prompts, thresholds and running server were not changed during
this comparison. The consumer was verified against the current source, including
the [speech-act arbitration fix](../speech-act-fix-20261017/README.md).

## Comparison

All 46 fixed semantic cases ran three times per model in each of two independent
BEAM processes. Model order was reversed in the second process. Each pair received
the same synthetic state, questions and real AppPolicy mapping, with no cache,
automatic retries, backend execution or order edits. Every successful API response
reported its requested pinned version. Expectations and selected-probability gates
remained unchanged: 0.8 for interpretation and 0.85 for clarification coverage.

| Policy outcomes | JEV 1.13.0 | JEV 1.14.0 |
| --- | --- | --- |
| Batch 1 | 133/138 | 132/138 |
| Batch 2, reversed model order | 135/138 | 133/138 |
| **Combined** | **268/276** | **265/276** |

Each model had 258 actual semantic API calls and 18 deterministic policy bypasses.
These are matches to fixed policy expectations on synthetic states, not estimates
of general model accuracy or production call success. Both full runs are retained:
[batch 1](results/batch-1.json), [batch 2](results/batch-2.json).

## Behaviors that determine the decision

Counts below combine all six attempts per case across both processes.

| Area | 1.13 passing | 1.14 passing |
| --- | --- | --- |
| Presence/audibility controls, including mixed business and pending clarification | 42/42 | 42/42 |
| Admitted read and retry continuations | 30/30 | 30/30 |
| Initial reads and operation changes after completed work | 42/42 | 42/42 |
| Explicit numeric/spoken corrections and corrections changing operation | 24/24 | 24/24 |
| Items request for a retained clarified order | **6/6** | **1/6** |
| Delayed numeric prefix correction (`120` + `three`) | **4/6** | **0/6** |
| Progress question about existing work | 0/6 | 6/6 |
| Other cases | 120/120 | 120/120 |

For the clarified-order case, active work concerns order 124 but the retained
clarification concerns order 123. The caller says “What items are in that order?”
The candidate identifies order 123 and selects items, but its selected items
probability is below 0.8 on five attempts (0.72–0.77); only one reaches 0.8. The
baseline returns 0.86–0.90 and admits all six requests. The candidate asks another
operation question instead of performing the already clear items lookup.

For the delayed correction, both versions identify order 123. Candidate replacement
probability remains 0.73–0.77 and fails all six attempts. The baseline reaches
0.8–0.83 on four attempts and clarifies on two. This uncertainty already exists in
the baseline, but migration increases its frequency in this comparison.

These failures concern primary intent or addition/replacement, not `speech_act`.
The repaired continuation and genuine presence controls pass on both models. The
candidate improves the progress question and has a lower observed API median
(109 ms versus 122 ms), but those gains do not satisfy the requirement to preserve
previously working request/correction behavior. The timing is a small sequential
API measurement, not a production latency benchmark. Thresholds were not lowered
to manufacture a passing migration result.

## Shared clarification model use

The existing 38 contextual clarification fixtures were also compared with the
application's 700 ms deadline, 0.85 gates and no retries:

| Model judgment | 1.13 | 1.14 |
| --- | --- | --- |
| Exact fixture outcome matches | 20/38 | 25/38 |
| Confident incorrect suppressions | 0 | 0 |

Most unmatched outcomes were conservative uncertainty. These are model judgments,
not the application's full fallback behavior. See [coverage evidence](results/coverage.json).
The complete revalidation made **592 API calls**: 516 semantic and 76 coverage.
No transport errors or pinned-model mismatches were observed.

## Provenance and reproduction

[Plan/source hashes](results/plan.json) and [computed summary](results/summary.json)
record the interpreter and runners used. This read-only revalidation made no
production code or dependency changes. The recent 230-test packaged check in the
speech-act fix remains applicable to the unchanged source; it was not rerun merely
to produce a second identical offline test result.

From the matching unpacked OrderDesk consumer, using a separate database:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=/tmp/order-desk-jev-revalidation.sqlite3 \
  python3 scripts/with_keychain.py mix run scripts/semantic_judgment_report.exs \
  /tmp/jev-revalidation-1.json --models jev-1.13.0,jev-1.14.0 --repeats 3

ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=/tmp/order-desk-jev-revalidation.sqlite3 \
  python3 scripts/with_keychain.py mix run scripts/semantic_judgment_report.exs \
  /tmp/jev-revalidation-2.json --models jev-1.14.0,jev-1.13.0 --repeats 3
```

The strict report exits nonzero if any expected case fails, including existing
baseline failures. Raw results are written before exit. The existing
`validation/jev-1.14-20261017/coverage.exs` runner accepts the contextual fixtures
path and a new output JSON path for the shared clarification comparison.

Do not replace the evidence with a selected successful repeat. Reconsider migration
after addressing the clarified-order intent and delayed-correction uncertainty,
or when a later model release passes the same request/correction cases reliably.
TypeSafe documents the [pinned model IDs and aliases](https://docs.typesafe.ai/models).
