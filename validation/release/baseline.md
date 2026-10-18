# Parlora browser release check: failed

Source: 4b03ebd6ecef5577a79653fb4c2d06af1b31c564 + uncommitted changes (hashes recorded).

## Offline checks

- passed: evaluator-tests
- passed: offline-acceptance
- passed: browser-recovery

## Paid model evaluation

18/21 scheduled attempts passed; 3 failed; 0 missing.
Complete batch: true. Incorrect-answer flags: 0; missing-answer flags: 1.
Application clarifications: 3; outside the permitted scenarios: 2.
Reply-check latency: 22 observations, p50 8173 ms, p95 16549 ms.

| Attempt | Outcome | Reason |
| --- | --- | --- |
| 01-cardinal-124-r1 | failed | Timed out: accepted status 124 with settled interpretation |
| 05-items-124-r1 | passed |  |
| 12-correction-r1 | passed |  |
| 14-followup-items-r1 | failed | Timed out: [missing-answer] status 124 |
| 19-spoken-approval-r1 | passed |  |
| 20-browser-confirmation-r1 | passed |  |
| 21-reconnect-r1 | passed |  |
| 01-cardinal-124-r2 | passed |  |
| 05-items-124-r2 | passed |  |
| 12-correction-r2 | passed |  |
| 14-followup-items-r2 | passed |  |
| 19-spoken-approval-r2 | passed |  |
| 20-browser-confirmation-r2 | passed |  |
| 21-reconnect-r2 | passed |  |
| 01-cardinal-124-r3 | passed |  |
| 05-items-124-r3 | passed |  |
| 12-correction-r3 | passed |  |
| 14-followup-items-r3 | failed | Timed out: accepted status 124 with settled interpretation |
| 19-spoken-approval-r3 | passed |  |
| 20-browser-confirmation-r3 | passed |  |
| 21-reconnect-r3 | passed |  |

Error: Paid evaluation contains failures or incomplete attempts

## Interpretation

Synthetic speech and bounded caption checks only. No human listening, accent coverage, phone-channel readiness, or production success-rate claim.
Latency is from fixture playback completion (or browser confirmation) to the successful reply check, including its one-second quiet observation. It is not first-audio or human-perceived latency. Failed waits are reported separately, not included as fast responses.
Incorrect/missing-answer counts are observed rule-based flags, not an exhaustive semantic audit. A backend failure can prevent reply assessment entirely. Recovery fault checks use a local protocol peer; paid reconnect trials are separate.
All scheduled attempts are retained. No retry replaces a failure. A comparison is descriptive and cannot establish significance.
