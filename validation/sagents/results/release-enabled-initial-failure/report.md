# Parlora browser release check: failed

Source: a3cc30e624c4b896b1603055735c7f51bd2d4650 + uncommitted changes (hashes recorded).

## Offline checks

- passed: evaluator-tests
- passed: offline-acceptance
- failed: browser-recovery
- passed: interpretation-diagnostics

Paid model evaluation: not run. An offline pass does not establish model response quality.

Error: Offline checks failed; paid evaluation not started

## Interpretation

Synthetic speech and bounded caption checks only. No human listening, accent coverage, phone-channel readiness, or production success-rate claim.
Latency is from fixture playback completion (or browser confirmation) to the successful reply check, including its one-second quiet observation. It is not first-audio or human-perceived latency. Failed waits are reported separately, not included as fast responses.
Incorrect/missing-answer counts are observed rule-based flags, not an exhaustive semantic audit. A backend failure can prevent reply assessment entirely. Recovery fault checks use a local protocol peer; paid reconnect trials are separate.
All scheduled attempts are retained. No retry replaces a failure. A comparison is descriptive and cannot establish significance.
