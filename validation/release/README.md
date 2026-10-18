# Browser release check

One command runs deterministic acceptance, evaluator regressions, and the local
browser timeout/reconnect test, plus a forced interpretation-timeout diagnostic test.
An explicit `--live` adds a fixed paid customer-task
batch. This is a browser release check, not certification of every Parlora channel
or human-perceived voice quality. See the [first baseline and reviewed failures](RESULTS.md).

```sh
# An existing consumer must match the current source. A missing one is built,
# tested and release-smoked automatically. Output directories must be new.
scripts/release_check.sh /absolute/consumer --output /absolute/new-check

# macOS only: seven scenarios × three attempts, sequentially, paid APIs.
BROWSER_CHANNEL=chromium scripts/release_check.sh /absolute/consumer \
  --output /absolute/new-live-check --live

# Same batch/scorer/environment, later code revision; descriptive comparison.
BROWSER_CHANNEL=chromium scripts/release_check.sh /absolute/new-consumer \
  --output /absolute/later-check --live \
  --baseline /absolute/new-live-check/report.json
```

Use the repository's pinned Elixir/Erlang/Rust/libopus setup. Install the locked
browser dependencies with `npm ci --prefix validation/browser`, then install
Chromium with `cd validation/browser && npx playwright install chromium`.
`BROWSER_CHANNEL=chromium` selects that downloaded browser; the shared runner's
default remains locally installed Chrome. Live speech uses macOS Samantha at
165 words/minute. The consumer's existing Keychain helper supplies paid service
credentials; they are never included in reports. Offline subprocesses receive no
OpenAI/TypeSafe API keys and use local peers and deterministic adapters.

## What runs

The existing CI workflow retains `mix ci`, stability tests, standalone consumer
checks, audio benchmarks and browser UI tests. The new command replaces its old
acceptance-only step and adds the newer checks on both OS jobs:

1. Node evaluator and runner regressions, including deliberately wrong/missing
   replies, stale answers, incomplete batches and incompatible comparisons.
2. Six existing deterministic OrderDesk acceptance scenarios.
3. Three real-browser recovery checks against a local protocol peer: withhold the
   acknowledgment, then acknowledge without producing conversational progress;
   each must display failure and enable reconnect. Finally complete exactly
   one lookup in a fresh session. These use committed synthetic PCM rather than
   macOS `say`, so the fixture is portable. Captions and interpretation are scripted.
4. A local stalled HTTP peer verifies interpretation-timeout phase capture without
   persisting credentials or request contents.

Offline failure prevents the paid batch from starting. The paid batch always has
these seven scenarios, each scheduled three times with a fresh session/database
(except the intentional two-session reconnect scenario):

| Scenario | Required outcome |
| --- | --- |
| Cardinal 124 lookup | One correct read; current delivery status; no other order ID in the result response |
| Items for 124 | Correct read and desk-lamp response; reject another order ID |
| Correct 123 to 124 | Exactly two lookups; final response after 124's completion refers to 124 |
| Status then items | Two distinct reads; both results answered in their own response windows |
| Spoken approval | Draft stays pending, database unchanged, concrete browser-confirmation instruction |
| Browser confirmation | Exact draft saved once for 124, other orders unchanged, saved destination announced |
| Reconnect | Pending draft retained, old work not replayed, fresh session answers one new items read |

All non-confirmation scenarios also compare the final saved orders with their
pre-scenario state. Pending drafts and final saved state are checked separately.
Each case has a 75-second scenario deadline. The underlying harness also has
bounded setup, request and cleanup waits. Repetitions are scheduled attempts, not
retries to erase failures. The command exits nonzero for a failed or incomplete
batch and retains every completed attempt and available partial report.

For optional transport diagnosis during the same paid batch, add
`--interpretation-diagnostics` alongside `--live`. See the
[timeout investigation](../interpretation-timeout/README.md). The diagnostic setting
is recorded in the plan; it changes the comparison key and adds no automatic retry.

## Response checks

Read replies are evaluated after the *current request's backend completion*.
This excludes earlier answers and acknowledgments that may name an old order.
Caller captions never satisfy an answer check. After a one-second quiet caption
interval, the check requires fixture facts, rejects other three-digit order IDs
recognized by the application parser, and rejects bounded explicit contradictions.
This applies to follow-ups and corrections as well as first reads.
Ordinary live task input waits for greeting generation to become idle and source
audio forwarding to remain quiet for 500 ms. Settled captions alone do not imply
that queued greeting audio has drained. This is a test synchronization condition,
not an application buffering change or proof of physical speaker completion.

Spoken approval requires an actual instruction such as clicking Confirm, rather
than the presence of words like “browser” or “confirmed.” A saved announcement
requires saved/updated language and the reception destination in the same sentence, after the explicit
browser action. The database remains the authority for whether saving occurred.

These are conservative fixture checks, not a semantic model or authoritative
speech endpoint. A legitimate paraphrase or explicit contrast with a prior order
may fail. An unsupported fact outside the checked patterns may escape detection.
Review failed evidence before attributing an evaluator failure to the product;
never edit a stored attempt to make it pass. No acoustic listening is claimed.

## Reports and provenance

Provider metadata matches the task runner: `PARLORA_PROVIDER=gemini` records
`gemini-3.8-live`; the default records `gpt-live-1`; `PARLORA_PROVIDER=grok`
records `grok-voice-3.0` and reasoning `high` by default. An explicit Grok `none`
selection remains a separate comparison. All providers record
`thinking_level: null`. The obsolete `GEMINI_THINKING_LEVEL` setting is ignored,
matching the standard Live runtime. These fields are part of the comparison key.
Historical reports retain their original metadata; a Gemini report labelled
Extended Thinking requires a fresh baseline rather than relabelling old evidence.
The same rule applies to historical Grok Voice Think Fast 2.0 reports: retain their
original model identifier and collect fresh Voice 3.0 evidence.

`plan.json` fixes the scenario inventory before execution. `report.json` and
`report.md` separate offline checks from model outcomes and include:

- Passed, failed and missing attempts, and zero-session cleanup evidence.
- Observed incorrect/missing-answer flags and application clarifications.
- Reply-check latency p50/p95, maximum and sample count. This measures from WAV
  completion or browser confirmation to assertion success, including the quiet
  observation period. It is not time to first audio or customer-perceived latency.
  Failed waits remain failures and are excluded from successful-reply quantiles.
- Source commit, dirty state, OS/runtime, harness hashes and verified consumer
  application/library source hashes. A stale installed consumer is rejected.
- Per-attempt evidence hashes and original error messages.

The report counts unexpected application clarifications using the scenario
allowlist; spoken approval can legitimately need clarification. It cannot count
all unnecessary spoken questions or all semantically incorrect answers. A failure
before a reply is assessed is not proof the reply was correct.

`--baseline` requires complete batches with identical scenario/scorer hashes,
model names, browser version/channel, runtime and repetition/concurrency settings. It gives descriptive
count and timing differences, not statistical confidence. Changed evaluators need
a fresh baseline; old reports are retained. Model aliases can change upstream even
when their names match, which limits causal comparisons.

Private audio, screenshots, provider/application transcripts, databases and logs
stay in the ignored output directory (`runs/` for repository-local runs). CI uploads
only the selected offline reports, logs and synthetic fault screenshots; it does
not upload the provider capture directory. CI never invokes `--live`.


## Qualification evidence

The first integration run was deliberately stopped after review found a
saved-announcement false positive. Its original attempts and errors remain in
[qualification.json](qualification.json); they are not merged into the release
baseline. The fix requires the saved claim and destination in the same sentence.
The exact captured truncated response is now a negative evaluator regression.
Interrupted workers also retain their incremental attempts in the terminal report,
and the aggregator can recover completed attempts without a terminal worker report.
