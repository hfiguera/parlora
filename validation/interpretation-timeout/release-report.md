# Parlora browser release check: failed

Source: a43efd9832f721d909f92efd984bd60be8c4413f + uncommitted changes (hashes recorded).

## Offline checks

- passed: evaluator-tests
- passed: offline-acceptance
- passed: browser-recovery

## Paid model evaluation

20/21 scheduled attempts passed; 1 failed; 0 missing.
Complete batch: true. Incorrect-answer flags: 0; missing-answer flags: 0.
Application clarifications: 0; outside the permitted scenarios: 0.
Reply-check latency: 25 observations, p50 7384 ms, p95 15225 ms.

| Attempt | Outcome | Reason |
| --- | --- | --- |
| 01-cardinal-124-r1 | passed |  |
| 05-items-124-r1 | passed |  |
| 12-correction-r1 | passed |  |
| 14-followup-items-r1 | passed |  |
| 19-spoken-approval-r1 | passed |  |
| 20-browser-confirmation-r1 | passed |  |
| 21-reconnect-r1 | passed |  |
| 01-cardinal-124-r2 | passed |  |
| 05-items-124-r2 | passed |  |
| 12-correction-r2 | passed |  |
| 14-followup-items-r2 | failed | Timed out: accepted status 124 with settled interpretation |
| 19-spoken-approval-r2 | passed |  |
| 20-browser-confirmation-r2 | passed |  |
| 21-reconnect-r2 | passed |  |
| 01-cardinal-124-r3 | passed |  |
| 05-items-124-r3 | passed |  |
| 12-correction-r3 | passed |  |
| 14-followup-items-r3 | passed |  |
| 19-spoken-approval-r3 | passed |  |
| 20-browser-confirmation-r3 | passed |  |
| 21-reconnect-r3 | passed |  |

## Baseline comparison

```json
{
  "comparable": false,
  "reason": "Requires complete batches with the same scenario/scorer hashes, models, browser, platform, repetitions and concurrency."
}
```

Error: Paid evaluation contains failures or incomplete attempts

## Interpretation

Synthetic speech and bounded caption checks only. No human listening, accent coverage, phone-channel readiness, or production success-rate claim.
Latency is from fixture playback completion (or browser confirmation) to the successful reply check, including its one-second quiet observation. It is not first-audio or human-perceived latency. Failed waits are reported separately, not included as fast responses.
Incorrect/missing-answer counts are observed rule-based flags, not an exhaustive semantic audit. A backend failure can prevent reply assessment entirely. Recovery fault checks use a local protocol peer; paid reconnect trials are separate.
All scheduled attempts are retained. No retry replaces a failure. A comparison is descriptive and cannot establish significance.
