# Silent-session investigation — September 22, 2026

**Fixed:** an unanswered provider command could leave a session marked ready with
no bounded failure/reconnect path. **Not proven:** why the provider failed to
acknowledge the command in the original session. Six new instrumented live trials
passed; the original failure did not recur. Human task evaluation was not run.

## Original evidence and causal limits

The source is `validation/task-pilot/runs/fix-r1/19-spoken-approval-r1.json` and its
worker's `server.log`. The session was ready, but there were no caller/assistant
caption events, delegation, interpretation calls, proposals, or backend jobs. The
browser completed its 3.8-second draft input clip. The greeting worker logged
`Greeting acknowledgment timed out` five seconds after readiness.

There was a 15.8-second browser PCM source gap, but it began **759 ms after the
input clip finished**, and the greeting was already missing. That gap cannot by
itself explain the missing opening response. Playback counters advanced; that does
not establish that speech was produced or heard. No raw provider trace was captured
for that original run, so we cannot prove remote receipt of the input, distinguish
provider timeline failure from every local/transport failure, or equate this case
with the previous Pipecat missing-caption incident.

Two application behaviors were established by code inspection:

1. `OrderDesk.Greeting` logged the missing acknowledgment and stopped waiting.
2. `Parlora.Providers.OpenAI` left the context command pending without a deadline.
   OrderDesk's independent 180-second session-duration limit was the remaining
   outer bound, not a useful response to this failure.

OpenAI documents that context acknowledgment follows the session timeline and may
remain pending if that timeline stops; acknowledgment is distinct from speech or
playback. It also requires continuous input audio during the greeting sequence.
These facts support the boundary being investigated, not a claim that OpenAI's
server caused this particular incident. See [Managing GPT-Live sessions](https://developers.openai.com/api/docs/guides/live-conversations#understand-when-context-reaches-the-model)
and [greeting guidance](https://developers.openai.com/api/docs/guides/live-conversations#greet-before-the-caller-speaks).

## Changes

- The OpenAI adapter's local `command_ack_timeout_ms` defaults to **30 seconds**.
  It applies to pending context and input-mute commands. A missing acknowledgment
  emits `:failed` with `cause: :command_ack_timeout`, reports pending outcomes as
  unknown, and closes the adapter/session. Positive integer configuration is
  validated. Acknowledged/rejected commands and sessions already closing ignore
  stale deadlines; duplicate commands do not reset the deadline.
- The browser now closes its media resources and displays an explicit reconnect
  message on failure. It does not automatically reconnect or replay work. Existing
  drafts remain available for review, and saved database state remains authoritative.
- Diagnostic schema 2 adds session identity, a full transmitted-input hash, and
  bounded received-event counters that continue beyond the detailed-record limit.
  The pilot can capture numeric browser RTP/media-source statistics before/after
  input and persist the provider report after closure, including bounded input PCM.
  Capture is opt-in, private, and excluded from source control.

The 30-second deadline is an application policy, **not a provider SLA**. Larger or
intentionally delayed context updates may need a longer configured deadline.
Silence without a pending command does not trigger it. It does not detect every
missing caption/reply after a successful acknowledgment, and it does not repair
provider recognition or network behavior.

## Validation

- **241 core checks passed:** 235 tests and 6 properties; 3 hardware/live/stability
  checks were excluded. Coverage includes missing acknowledgment, late deadlines
  after acknowledgment/rejection/close, unknown pending outcomes, local option
  validation, redaction, bounded capture, and counters surviving record truncation.
- **149 OrderDesk tests passed** in a fresh standalone consumer built from the
  modified source package. Its production release smoke passed as well.
- **8 Node checks passed**, plus syntax, formatting, and diff checks.
- **2/2 browser fault/recovery checks passed.** A loopback WebSocket peer uses the
  real OpenAI adapter callbacks and browser media path, but deliberately withholds
  the first connection's acknowledgment. A shortened 1.5-second test deadline
  produces the visible failure message and enabled reconnect controls. A fresh
  connection accepts commands and completes exactly one read of 124; saved orders
  are unchanged and cleanup reports zero sessions. Provider captions and classifier
  answers in this fixture are scripted; it is not live-model accuracy evidence.
- **6/6 paid live trials passed:** cardinal 124 lookup and spoken draft approval,
  each repeated three times across three independent workers. Every trial produced
  its provider capture and ended with zero sessions. Greeting acknowledgments took
  1.13–1.39 seconds. Captured provider-bound PCM was nonzero and untruncated; its
  hash matched the full transmitted-stream hash. Caller captions and provider
  acknowledgments arrived in all six sessions. Two traces exhausted the detailed
  event limit (155 and 80 omitted records), while aggregate received counts remained
  available. No unauthorized save occurred.

See [live-results.json](live-results.json) and [fault-results.json](fault-results.json)
for compact evidence and hashes. Full local artifacts are ignored under `runs/`
and `../task-pilot/runs/silence-diag-r{1,2,3}/`. Prototype fixture failures are retained
and explained in `fault-results.json`; they are not silently replaced with passes.

Transport-sent bytes mean handed to the local WebSocket transport, not proof of
remote receipt. Browser energy/packet counts and PCM peaks locate activity along
the path; they are not intelligibility or human listening scores. These six trials
are too small to estimate outage frequency or prove the upstream issue fixed.

## Public human-recording search

The user asked to use a suitable public dataset or skip this phase. I searched
public human speech/task-dialogue datasets and inspected the cached Pipecat manifest
and SLURP's public test annotations. No human-voice task run was performed.

| Candidate | Finding and fit |
| --- | --- |
| [SLURP](https://github.com/pswietojanski/slurp) | Real recordings and speaker/microphone metadata are available. Its test annotations contain related takeaway-status questions, but not the numbered-order/correction/draft-confirmation task sequences needed here. It could support a narrower missing-number study, which would not establish the planned task coverage. The publisher separately labels its audio CC BY-NC 4.0. |
| [SpokenWOZ](https://spokenwoz.github.io/) | Public human-to-human task conversations and labels exist across other service domains. I did not find a ready mapping to these supported OrderDesk tasks; replaying unrelated tasks as order actions would create misleading outcomes. |
| [Pipecat STT benchmark](https://huggingface.co/datasets/pipecat-ai/stt-benchmark-data) | Existing 1,000-clip caption benchmark. It includes order-related speech and numbers in other contexts, but no paired OrderDesk conversation/action labels or verified speaker coverage for this proposed human-task pilot. It remains the separate caption evaluation. |

The inspected SLURP `test.jsonl` had 2,974 entries; 39 matched the bounded search
for order/package/delivery/parcel/tracking. The source text SHA-256 was
`fe3449af69b42fda7163345482556066c35a80f7e552a6d67e212a0e2f0783cc`.
This is a search result and suitability judgment, not a claim that no usable public
human recordings exist anywhere. No synthetic audio is counted as human coverage.

## Reproduce

Build an isolated standalone consumer:

```sh
scripts/consumer.sh /absolute/new/silent-session-consumer
```

Run the local fault/recovery fixture without an API key or microphone:

```sh
mkdir -p validation/silent-session/runs
node validation/silent-session/fault_test.cjs /absolute/new/silent-session-consumer \
  validation/silent-session/runs/new-fault-run
```

Run the explicitly billable diagnostic pilot using the existing Keychain helper:

```sh
node validation/task-pilot/run.cjs /absolute/new/silent-session-consumer \
  validation/task-pilot/runs/new-diagnostic-run --live --diagnostics \
  --repetitions 3 --cases 01-cardinal-124,19-spoken-approval
python3 validation/silent-session/analyze.py \
  validation/task-pilot/runs/new-diagnostic-run \
  --output validation/silent-session/runs/new-summary.json
```

Use new output paths. Raw PCM and transcripts remain local under ignored run
folders with restricted permissions. The diagnostics collector and fault provider
are validation-only modules; normal application startup does not load them.


The [release check](../release/README.md) now runs the local browser fault/recovery
fixture in CI. Its input is the committed synthetic speech WAV, reused only to
exercise real PCM transport; local peer captions remain scripted. This removes the
fixture's macOS speech-generation dependency without changing the historical
results above. Paid task evaluation remains separately opted in.

## Subsequent progress recovery

The [session-health change](../session-health/README.md) adds a separate, opt-in
host progress deadline and a third browser fixture: acknowledge the opening
commands but produce no conversational progress. OrderDesk enables that opening
check. This extends recovery coverage without establishing the original outage's
cause or changing the historical results above.
