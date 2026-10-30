# OrderDesk interpretation scheduling validation

The original scheduling changes exercise the example application without changing
provider adapters. The [stall follow-up](stall-investigation.md) isolates and fixes
two Phonic continuation defects and corrects a harness wording assumption. Other
adapters, session validation, JEV model, confidence thresholds, number normalization,
and database confirmation rules remain unchanged.

## Deterministic regressions

From `examples/order_desk`:

```sh
mix test --warnings-as-errors
node --test test/*_test.cjs
node --check priv/browser/orders.js
mix compile --warnings-as-errors
```

`test/interpretation_scheduling_test.exs` covers skipping a revised snapshot
before an evaluation, discarding an in-flight stale result, separating uncertainty
from errors, actor-scoped session metrics, cache isolation, fresh verification,
closed sessions, and resuming a real deferred session after speech becomes idle
without another caller event. Its policy cases cover all four provider selections,
unknown speech state, new caller input, explicit delegations, backend clarification,
and application context updates. The last three bypass caption deferral.

## Live provider workflow

Requires existing provider/TypeSafe credentials, macOS `say`, and `ffmpeg`.
Generate synthetic speech from fictional order requests:

```sh
python3 validation/interpretation-scheduling/generate_clips.py /tmp/orderdesk-scheduling-clips
cd examples/order_desk
PARLORA_PROVIDER=phonic ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
  python3 scripts/with_keychain.py mix run --no-compile \
  ../../validation/interpretation-scheduling/order_desk_live.exs \
  /tmp/orderdesk-scheduling-clips /tmp/orderdesk-phonic.json
```

Repeat with `openai`, `gemini`, and `grok`. Reports contain synthetic captions and
judgment evidence; raw generated reports are ignored by Git. No microphone or
user database is used. The script requires an in-memory database and saves only
fictional data there.

The scenario corrects order 123 to 124 while the original lookup is pending,
checks items using “that order,” requests an edit without wording, supplies the
wording, rejects that draft, creates another draft, and explicitly confirms it
through the application's confirmation API. Assertions require six backend
operations without duplicates, a discarded stale lookup, the correct order and
items, two delivery drafts, a rejected draft, exactly one persisted change, and
spoken save confirmation. Before confirmation, it verifies zero saved changes
and record version 1. It waits for speech/output to settle between turns; only
the correction deliberately interrupts pending work. Output audibility uses a
PCM peak threshold of 256 because some providers stream silent output continuously.

The clarification phrase in the reusable fixture is “for that order.” An earlier
Gemini attempt transcribed “one hundred twenty four” as “10024,” which correctly
required a number clarification outside this fixture's prepared reply. Number
normalization remains outside this patch.

## Same-input Phonic comparison

`comparison-summary.json` retains compact before/after observations from the
three-operation fixture at `validation/phonic/order_desk_delegation.exs`: items
for order 124, current delivery instructions, then a reception draft without
saving it. Both use `phonic-1` and `jev-1.13.0`. These are live observations, not
guaranteed reductions for every conversation.

To measure the current implementation with the same three generated clips:

```sh
# From examples/order_desk; clips must contain items.pcm, instructions.pcm, draft.pcm.
PARLORA_PROVIDER=phonic ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
INTERPRETATION_REPORT=/tmp/phonic-interpretation.json \
  python3 scripts/with_keychain.py mix run --no-compile \
  ../../validation/interpretation-scheduling/measure_phonic.exs \
  /tmp/phonic-orderdesk-no-chaining-clips /tmp/phonic-workflow.json
```

The measurement wrapper captures each judgment and policy telemetry, including
core discards after the final freshness check. It retains evidence even if the
workflow fails; inspect the workflow report's `passed` field separately. Counts
of deferred policy evaluations represent cheap rechecks, not TypeSafe calls.

## Observed results (2026-10-29)

The table below retains the scheduling-patch observations at `69f4fd5`. For subsequent
fixes, repeated live passes, and remaining evidence limits, see the
[stall investigation](stall-investigation.md).

| Check | Result |
| --- | --- |
| OrderDesk tests, warnings as errors | 248 passed |
| Library provider regression tests (all four adapters/protocols/contracts) | 123 passed |
| Browser JavaScript tests and syntax | 3 passed; syntax valid |
| Phonic three-operation fixture, final code | Passed all assertions |
| OpenAI longer live workflow, final code | Passed all 12 assertions |
| Grok longer live workflow, final code | Passed all 12 assertions |
| Gemini longer live workflow, final code | Timed out after items task/late delegation association; no adapter failure |
| Phonic longer live workflow, final code | Timed out after correction/late delegation associations; no adapter failure |

For the same successful three-operation Phonic scenario:

| Observation | Before | After |
| --- | ---: | ---: |
| JEV evaluations | 33 | 18 |
| Evaluations discarded by core as superseded | 21 | 11 |
| Uncertain judgments | 16 | 8 |
| Errors | 0 | 0 |
| Skips before evaluation | not measured | 11 |

That is 45% fewer evaluations in this successful before/after pair. The final
freshness counter observed 10 stale results; core discarded 11 because another
revision can arrive after the last check. Average network evaluation latency
was higher in the later run (177 ms versus 136 ms); this patch reduces request
volume and does not establish a network latency improvement.

`comparison-summary.json` records the measurement and final Phonic workflow
assertions. `providers-summary.json` also records failed longer attempts and a
successful baseline Phonic stress run. Earlier development runs included a
Phonic provider `response_timeout`, Gemini order transcription/uncertainty, and
harness wording/timing assumptions. That harness accepted varied save wording
and waited for output to settle, but still required question punctuation. At that
point, the final live stalls had not been isolated and the larger workflow was
not fully qualified across all providers. The [follow-up](stall-investigation.md)
records the subsequent controlled reproductions, fixes, passes, and remaining
limits. Passing offline tests and a finite set of successful scenarios do not
guarantee that every live conversation succeeds.
