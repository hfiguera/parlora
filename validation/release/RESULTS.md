# Browser release baseline — September 22, 2026

**The release command works and correctly returns failure for this baseline.**
All offline checks passed. The complete paid batch had **18 passed and 3 failed
out of 21 scheduled attempts**. The failures were retained without retry or
threshold changes. This is a small synthetic-speech baseline, not a customer
success-rate estimate or production-readiness certification.

See the generated [report](baseline.md), [machine-readable baseline](baseline.json),
and [review of final state and failures](review.json). Usage is in [README.md](README.md).

## What changed

- `scripts/release_check.sh` combines evaluator regressions, deterministic
  application acceptance and browser fault/recovery checks. Explicit `--live`
  adds the fixed paid batch; optional `--baseline` compares compatible runs.
- CI now invokes the offline command on its macOS/Linux matrix and preserves
  selected reports. Existing core, consumer, stability, audio and UI checks remain.
  Hosted CI and the new command on Linux were **not executed from this workspace**.
- Response assertions now follow the matching backend completion, check IDs on
  corrections/follow-ups, require actionable confirmation instructions and a
  complete saved-destination statement, and retain independent reply evidence.
- Final read-job inventories reject extra work, saved-state comparisons cover the
  non-save scenarios, and reconnect verifies a fresh session with no replay.
- Source hashes and installed-consumer verification prevent accidentally testing
  stale application/library code. Reports retain incomplete attempts and separate
  local fault fixtures from paid model behavior.

These changes improve the evaluation and regression protection. They do not fix
or establish the causes of the runtime failures below.

## Offline validation

- **17 Node checks passed**, including wrong-order responses, stale reply windows,
  missing confirmation instructions, the captured save-announcement false positive,
  incompatible comparisons and interrupted-worker evidence retention.
- **6/6 deterministic application acceptance scenarios passed.**
- **2/2 browser fault/recovery scenarios passed**, using Chromium and a local
  protocol peer with synthetic PCM. These demonstrate timeout UI, reconnect,
  exactly one fresh read, unchanged saved state and zero active sessions.
- A fresh standalone consumer built from the source package passed **149 application
  tests**, compilation/formatting checks and its production-release smoke.
- JavaScript/shell syntax checks and `git diff --check` passed.

No production Elixir or frontend runtime code changed in this work. Existing core
checks remain in CI; the previous core suite result is not presented as a new run.

## Fixed paid batch

Runtime application/library sources matched `4b03ebd`; the uncommitted evaluation
changes are identified by hashes in the baseline. All frozen evaluation hashes
were verified after the run. macOS arm64, Node 26.8.2, Chromium 151.0.7922.34,
GPT-Live-1, TypeSafe jev-1.13.0, Samantha at 165 words/minute. One sequential worker,
three scheduled repetitions, isolated databases, 75-second scenario deadlines.

| Scenario | Passed / scheduled |
| --- | --- |
| Cardinal 124 lookup | 2/3 |
| Items for 124 | 3/3 |
| Correct 123 to 124 | 3/3 |
| Status then items | 1/3 |
| Spoken approval preserves pending draft | 3/3 |
| Browser confirmation saves and announces destination | 3/3 |
| Reconnect retains draft and performs a fresh read | 3/3 |

All 21 attempts completed and final cleanup reported **zero active sessions**.
A separate review of all 21 final database snapshots found only the three expected
browser-confirmed changes, each for order 124 with exactly one version increase.
Other scenarios left saved orders unchanged. No wrong-order response was flagged;
this is bounded caption evidence, not proof that every spoken fact was correct.

### Two interpretation-timeout failures

`01-cardinal-124-r1` and `14-followup-items-r3` correctly transcribed the request
for 124, but each recorded four interpretation judgments returning `{:error, :timeout}`.
No backend job started. The assistant gave an unavailable/try-again response.
The follow-up case therefore failed on its initial lookup before reaching items.

This identifies the failed stage. It does not establish whether upstream latency,
local scheduling, request transport, or the configured time budget caused it.
These repeated timeouts are the clearest runtime follow-up from this batch.

### One response-specificity failure

`14-followup-items-r1` selected the correct order and delivered its backend result,
but the assistant said “Order 124 is on its way.” The fixed check requires the
stored status, “out for delivery.” It timed out before issuing the items follow-up.

This is a specificity/check-boundary failure, **not proof of a wrong lookup or a
false factual statement**. “On its way” is compatible with the stored status but
also with other shipping stages. The original failure remains unchanged; no
post-run widening of the matcher was applied.

### Timing observations

There were 22 successful explicit reply checks: **p50 8,173 ms**, **p95 16,549 ms**,
maximum **18,273 ms**. These measure from fixture playback completion (or browser
confirmation) to assertion success, including the one-second quiet-caption check.
They are not first-audio or microphone-to-ear latency. Failed waits are excluded
from these quantiles and remain separate failed attempts. No latency SLO is claimed.

## Evaluator qualification, kept separate

Before this baseline, an integration run was stopped after manual review found a
false-positive save-announcement check. “Reception” from an earlier draft sentence
was incorrectly combined with a later unfinished “It's saved for order 124:” claim.
The corrected scorer requires the destination in the saved-claim sentence.

That run retained nine attempts: seven automated passes (including the invalid
save check), one missing-confirmation failure, and one session-closing failure
observed during the deliberate interruption. It is **not** a comparable baseline,
and its outcomes are not pooled with the 21 attempts above. Original outcome and
evidence hashes are retained in [qualification.json](qualification.json).

The fresh baseline does not erase the earlier missing-confirmation failure. All
three new approval attempts passed, which establishes neither its cause nor a fix.
Raw synthetic audio, transcripts, databases, screenshots and logs remain in ignored
`runs/baseline-20260922` and `runs/baseline-v2-20260922`. No human-voice phase was run.
