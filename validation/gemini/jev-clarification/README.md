# JEV clarification coordination pilot — September 24, 2026

**Historical report, superseded by the [contextual audit and integration](INTEGRATION.md).**
The initial rejection below over-weighted a constructed, ambiguous quotation case.
Its original labels/results remain intact for audit; they are not established
ground truth for whether a listener would understand that sentence as a request.

**Decision: do not enable this design in the running application.** A semantic
comparison helps on paraphrases and unrelated questions, but both tested designs
confidently suppressed a needed clarification on quoted text. The application,
library, live servers, credentials and Telnyx routing are unchanged by this pilot.

## Question and acceptance criteria

Does the assistant's latest observed utterance already request the information
that the application proposes to clarify? Evaluate meaning, including missing
fields, rather than question punctuation. JEV may recommend only suppressing or
retaining a clarification; it must not select business actions or authorize saves.

The integration decision requires improved decision accuracy, no incorrect
suppression in the evaluated cases, and requests below the 700 ms budget. Timeout,
uncertainty and malformed answers would fall back to existing behavior. Aggregate
accuracy alone is insufficient if a new confident mistake hides a needed question.
This gate is a diagnostic requirement, not a production accuracy guarantee.

## Evidence

The application-configured `jev-1.13.0` client was used with a per-request 700 ms
deadline and one attempt. Credentials came from the existing Keychain launcher,
through process environment only. There were **76 live API requests**, no voice
calls and no microphone recording. Each reported latency includes the API request
but excludes the normal intent interpreter's separate 200 ms coalescing delay.
These tests do not establish end-to-end conversation latency or billing totals.

| Variant | Evaluations | Correct decisions with fallback | Existing rules | Confident wrong suppressions | Median / p95 |
| --- | --- | --- | --- | --- | --- |
| v1: coverage comparison | 34 | 27/34 | 20/34 | 2 | 99 / 183 ms |
| v2: caller-request + coverage, batched | 42 | 33/42 | 22/42 | 1 | 118 / 267 ms |

No API errors or deadline expirations occurred. Maximum latency was 437 ms for
v1 and 428 ms for v2. v1 abstained on 11 evaluations, v2 on 22; abstentions use
the current rules in the table. Exact three-way labels separately scored 22/34
and 20/42. Conservative abstention is not counted as a confident wrong answer.

The retained reports contain the raw choices/probabilities:
[v1](pilot-v1.json), [v2](pilot-v2.json), and [summary](summary.json).
Model probabilities are not measured real-world accuracy.

Both variants treated **“The instructions say please provide a three-digit order
number”** as a current request to the caller. v1 also treated **“I need to look up
your order number”** as such a request. These are regressions compared with the
existing deterministic rules on those examples. In v2, falling back on an
uncertain judgment also retains the existing false suppression for a question
covering only part of the proposed missing information. Confidence thresholds
alone therefore did not make this candidate ready to replace the existing logic.

## Dataset and limits

[cases.json](cases.json) contains observed transcript examples and constructed
regressions/paraphrases, with human-readable expected labels. The original 14
regressions ran once and ten initially held-out cases ran twice (34 evaluations).
After inspecting v1, v2 added a separate communicative-act question in the same
request, retained the 0.85 threshold, and added eight fresh held-out cases, run
once. Both versions' prompts are retained in [judgment.exs](judgment.exs).
The old rules were evaluated from commit `9c9678c`.

The samples are small and deliberately adversarial. v1 and v2 have different
sample sets, so their totals are not a direct accuracy ranking. Repeated cases
are repeated requests, not additional independent examples. The pilot is not a
general benchmark of JEV, multilingual speech recognition, or phone quality.
It does demonstrate why this particular integration should not yet ship.

## Replay

From a synchronized standalone OrderDesk consumer with its dependencies installed:

```sh
# Offline confidence/abstention and question-contract tests (no credentials).
mix run /Users/humberto/Projects/parlora/validation/gemini/jev-clarification/test.exs

# Explicit live opt-in; these replace the corresponding saved report.
PARLORA_PROVIDER=gemini ORDER_DESK_TYPESAFE=1 \
ORDER_DESK_DATABASE=/tmp/parlora-jev-clarification-pilot.sqlite3 \
python3 scripts/with_keychain.py mix run \
/Users/humberto/Projects/parlora/validation/gemini/jev-clarification/pilot.exs --live v1
# Replace v1 with v2 for the 42-request two-question variant.
```

The pilot module is loaded only by the standalone scripts; it is not in the
application's compilation paths. The existing TypeSafe intent/target integration
continues unchanged. Offline tests verify uncertainty handling, confidence
boundaries, the v2 two-answer requirement and batched question construction.
Run `python3 summarize.py` here to recompute the comparison without network access.

Since the accuracy gate failed, no runtime cache, policy/speech integration or
production stale-result behavior was added or claimed verified. Those remain
requirements for a future candidate that passes the semantic pilot. Three offline
tests passed on macOS and Linux; no production source changed, so the prior full
application/library results were not rerun for these diagnostic artifacts.
