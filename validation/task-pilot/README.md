# Recorded-audio OrderDesk task pilot

The original pilot used twenty predefined customer-task scenarios, each scheduled
three times. A twenty-first scenario now checks reconnect and a fresh read. This adds
outcome checks to caption evaluation: actual backend targets and operations,
accepted results, assistant reply captions, draft state, and saved SQLite state.
See [the pilot results](RESULTS.md) for findings, fixes, and unresolved cases.

`scenarios.cjs` defines the caller audio and expected outcomes before execution.

The pilot reuses `validation/acceptance/live.cjs` and its real browser WebRTC path.
It uses macOS Samantha synthetic speech (165 words/minute), GPT-Live-1, the real
TypeSafe interpreter, AppPolicy, Jido, and an isolated demo database. Every case
gets a fresh database, browser identity, session, and empty interpretation cache.
No microphone or existing application database is used. References/expected
outcomes are never passed to the provider. Each case has a 75-second deadline.

A bounded greeting wait precedes caller audio: at least two seconds, then one
second without an assistant caption, with a seven-second maximum. This is a test
precondition, not a product fix or a claim of an authoritative speech boundary.
A separate initial smoke attempt that spoke during the greeting is preserved.

## Run

Create a fresh standalone app (this also validates its existing tests):

```sh
scripts/consumer.sh /absolute/new/pilot-consumer
node --test validation/task-pilot/*test.cjs validation/acceptance/runner_test.cjs
mkdir -p validation/task-pilot/runs
node validation/task-pilot/run.cjs /absolute/new/pilot-consumer \
  validation/task-pilot/runs/new-pilot --live
```

`--live` is mandatory and makes paid GPT-Live and TypeSafe requests. The existing
consumer Keychain helper supplies credentials to its server process. They are
never written to reports or sent to browser code. Browser dependencies use the
existing locked `validation/browser` installation. Output directories must be new.

For a small smoke run, use `--repetitions 1 --cases 01-cardinal-124,09-missing-number`.
For independent repetition workers, use `--repetitions 1 --repetition-start N`
(N = 1, 2, or 3), with a different output directory per worker. Each worker has its
own server, browser, databases, and port. Report worker concurrency when quoting
latency. Scheduled repetitions do not replace failed attempts.

## Evidence and limits

`plan.json` records expectations, source hashes, and source commit. `report.json`
records outcomes, cleanup, timing, and generated audio hashes. Every case retains
browser transcript/events, application jobs and status, database checkpoints,
TypeSafe judgments and policy decisions, and a screenshot. Raw per-case evidence,
audio, logs, and databases stay under ignored `runs/`. The test-only server binds
to loopback; reset and interpretation routes never load in the normal app.

An outcome cannot pass from matching caller words or an earlier assistant reply.
Backend state and the current assistant response must satisfy each case's checks.
Clear requests also fail on unnecessary application clarification. Database writes
are checked independently: voice cannot save drafts, while explicit browser
confirmation must update only the displayed order and increment its version once.

This is a small synthetic-speech pilot, not production success-rate certification.
Assistant reply evidence comes from provider captions, not human listening or
acoustic playback verification. Rule-based reply checks can themselves be too
narrow; preserve the original failure and inspect its evidence before labeling a
product defect. Instrumentation observes the app and does not inject captions or
classifier answers. Single-order read replies also reject other three-digit IDs
recognized by the demo parser; this does not validate every number or a full response.
Pipecat clips remain a separate caption benchmark; they have
no OrderDesk outcome labels.


To aggregate completed repetition workers without changing their original outcomes:

```sh
python3 validation/task-pilot/analyze.py \
  validation/task-pilot/runs/baseline-r1 \
  validation/task-pilot/runs/baseline-r2 \
  validation/task-pilot/runs/baseline-r3 \
  --output validation/task-pilot/runs/new-analysis
```

Duplicate trial IDs and incomplete workers are rejected. Keep later rechecks in a
separate aggregate. The current runner records standalone application source hashes
as well as harness hashes; baseline runs predate that additional provenance capture.
The baseline standalone app was built from `4fcf0ac` before application changes.


Add `--diagnostics` to an explicitly authorized diagnostic run to capture numeric
browser media statistics before/after input and the provider's bounded report after
closure. Raw transmitted input PCM and private metadata are stored in that run's
`provider/` directory. This mode is off by default. See
[the silent-session investigation](../silent-session/README.md).


The [browser release check](../release/README.md) selects seven scenarios for a
fixed, sequential release baseline. Current read checks start at the matching
backend completion, also validate follow-up/correction response IDs, and retain
explicit reply-check records. Spoken approval now requires a concrete confirmation
instruction; browser confirmation also requires a saved-destination announcement.
These stricter assertions do not retroactively change earlier pilot results.


`--interpretation-diagnostics` separately enables bounded, private TypeSafe transport
phase sampling. It does not change the request deadline or retry policy. See the
[interpretation-timeout investigation](../interpretation-timeout/README.md).
