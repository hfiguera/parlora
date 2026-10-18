# Contextual audit and JEV integration — September 24, 2026

JEV clarification comparison is now enabled for Gemini in OrderDesk. The initial
pilot's rejection was too strong: the constructed sentence “The instructions say
please provide a three-digit order number” can reasonably relay a current request.
Its label was not established ground truth for the product's desired behavior.
The earlier zero-regression gate also did not adequately weigh the improvement
over rules that themselves suppress unrelated questions.

The original reports and labels are retained. The new campaign removes the two
context-free quotation examples and replaces them with explicit current-request
and historical-quotation pairs. It also repairs the multiple-fields fixture so
`missing` includes both order and operation, matching its proposed message.
It does not silently relabel old results as successes.

## Contextual comparison

[contextual-cases.json](contextual-cases.json) contains 30 prior examples and eight
new contextual examples. Prior examples ran once; the eight new examples ran twice:
**46 live JEV evaluations, 38 distinct examples**. The prompt now considers
conversation context and permits indirect/relayed current requests rather than
blanket-excluding quotations. The confidence threshold remains 0.85.

| Measure | Result |
| --- | --- |
| JEV plus existing-rule fallback | **38/46** correct suppression decisions |
| Existing rules on the same inputs | **23/46** |
| Confident incorrect JEV suppressions | **0 observed** |
| Median / p95 request latency | **112 / 148 ms** |
| Longest request | **448 ms** |

See [raw choices/probabilities and timings](contextual-results.json). Uncertain
answers still occur, including on historical quotations; the combined result
includes fallback and is not JEV-only accuracy. Repeated examples are not
independent samples. This remains a small, adversarial text comparison, not a
production accuracy estimate or end-to-end handset qualification.

Run `contextual-pilot.exs --live` from a synchronized consumer through the existing
Keychain launcher to replay 46 billable evaluations. It writes the contextual
report. Its baseline snapshot uses unknown speech state, exercising the retained
original rules without invoking the new runtime comparison. The production prompt
is in `OrderDesk.ClarificationCoverage`.

## Runtime contract

- Only a proposed Gemini clarification with a latest assistant utterance and
  provider speech `:idle` is eligible. Business decisions, new caller input,
  speaking, OpenAI, and pending browser-save holds bypass this model request.
- Two choice questions share one TypeSafe request: current caller request and
  coverage of the missing information. This is an additional request after intent
  interpretation, because the proposed clarification is derived from that result.
  It has a 700 ms request deadline and one attempt, without another 200 ms
  coalescing delay. A 16 KiB state bound avoids unbounded context.
- The existing 128-entry cache separates intent and clarification keys. Cache
  keys contain semantic state including recent dialogue and the proposed missing
  information. Successful results retain the existing 60-second cache TTL;
  uncertainty/errors use 500 ms. No API call occurs for every speech fragment.
- Unknown/failed judgments use the original local rules. Suppression schedules
  a fresh policy recheck, bounded by **eight seconds from the first idle candidate
  for the caller revision and target**. Inference time consumes that budget.
  Expired windows cannot be renewed by another assistant caption or duplicate
  delegation for the same task. After expiry the current clarification is allowed;
  the application does not resubmit a queued old question.
- The separate 128-entry window ledger keeps expired deadlines for five minutes,
  beyond the demo's 180-second session limit, and permits clarification on overflow.
  The recovery state recognizes coverage waits, so expiry cannot restart a new
  settle/verify/suppression loop. Normal clarification deduplication then applies.
- `ContextSnapshot.provider_speech` exposes `:unknown | :speaking | :idle`.
  A change revises context; the existing asynchronous policy runner discards
  judgments computed before new speech state or caller input. Model inference
  runs outside the audio path. Provider idle is not proof of playback or hearing.
- Legacy snapshots with unknown speech state retain the original rules. The
  known-idle Gemini path, including its fallback, uses the new bounded wait.
  Business validation, execution, save permissions and task revisions remain in
  application code. The model never rewrites a number or delivery instruction.

An additional [live cache probe](cache-probe.json) used one real JEV evaluation
and then a cache hit with the same semantic state. Its [runner](cache-probe.exs)
requires `--live`. This makes **47 new live evaluations** beyond the historical
76. No Gemini voice request or human recording was needed for this campaign.

## Verification

| Check | macOS | Linux |
| --- | --- | --- |
| Complete OrderDesk suite | [189 passed](integration-checks/macos-orderdesk.log) | [189 passed](integration-checks/linux-orderdesk.log) |
| Repository `mix ci` | [289 tests/properties; passed](integration-checks/macos-ci.log) | [289 tests/properties; passed](integration-checks/linux-ci.log) |
| Additional session lifecycle regression | 1 passed | 1 passed |

The lifecycle regression was added after the full application run and executed
separately on both platforms. It drives a real session with the offline provider
and an injected short test clock: suppression schedules a recheck, expiry submits
one fresh clarification, no backend job executes, and the question is not
repeated. The production eight-second deadline, non-renewal and capacity behavior
are separately covered. Other tests exercise semantic override, fallback,
inference consuming the deadline, provider gating, save holds, preservation of
business decisions and context while a stale judgment is discarded. The session
test also verifies audio continues while the policy worker is waiting.

Repository checks include native tests, format, Credo, clone detection, Credence
and Dialyzer; three existing stability exclusions remain. No credentials or
microphone recordings are included in this report.

Both idle local servers were restarted with the new source, preserving their
separate test databases and saving the previous phone diagnostics under `/tmp`.
The browser and phone review pages were refreshed. A new human call is still
needed to evaluate the changed conversation behavior. ASR errors and intermittent
Gemini delays remain outside this fix. Telnyx routing was not modified; its
previously reported original-route restoration uncertainty remains unresolved.
