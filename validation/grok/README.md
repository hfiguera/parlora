# Grok Voice Think Fast 2.0 evidence

This is historical evidence. The current adapter uses Voice 3.0; see the
[Voice 3.0 migration checks](voice-3-20261017/README.md) for its separate results.

These are bounded synthetic-speech probes against pinned
`grok-voice-think-fast-2.0`. Reasoning and codec are recorded per attempt; HIGH and
NONE are not pooled. Credentials, resumption handles, and raw audio are not saved.

The initial HIGH/PCM pending-work probe answered "Paris" while the original lookup
was unresolved, then announced Friday after result submission. Two HIGH/PCM
correction probes with a one-second gap emitted no second speech-start or caller
caption and failed. They remain failures. A separate three-second-gap correction
received a replacement call before result submission and announced only order 124.
This isolates a timing-sensitive observed limitation, not its internal cause.

The HIGH/PCM interruption protocol probe stopped a long counting response and
answered "Hello". NONE/PCMU pending-work and correction probes also passed.
These are narrow protocol observations, not an acoustic assessment or statistical
reliability estimate. The correction harness closes superseded calls without
submitting obsolete business facts, matching application-owned stale-result policy.

The production-adapter PCM probe transcribed the caller once, emitted a delegation,
accepted a delayed result with unconfirmed socket submission, and announced Friday.
The first six-case OrderDesk batch passed. The next batch retained one
`output_overflow` failure during the spoken draft confirmation, before the save
announcement. The initial 10-second profile was insufficient for that burst; the
Grok profile now permits 20 seconds and expires retained audio after 21 seconds.
This is an explicit bounded profile change, not a retry replacing a failed trial.

The initial independent-work probe used an ambiguous follow-up, overlapped the
slow-result release with the fast response, and ended before observing the original
result. It remains a failed diagnostic attempt. The separate 25-second-delay probe
announced order 124's result while order 123 was pending, then announced order 123's
result. Response groups, rather than all pending calls globally, gate continuations.
Loopback tests separately cover multiple calls within one response.

The 20-second-profile save retest passed both cases. The final response-group
implementation passed three separate OrderDesk cases: slow correction, browser
confirmation, and independently confirmed save announcement. These batches remain
separate attempts; they are not pooled into a reliability rate.

The production-adapter NONE/PCMU probe also passed. A production Session with both
audio pipelines and a memory channel observed interruption, a matching clear epoch,
zero stale frames after clear, and fresh output. This does not establish physical
speaker behavior.

The final core CI passed 306 checks (six properties and 300 tests), with three
excluded tests, plus native Rust tests, formatting, Credo/ExSlop, ExDNA, Credence,
and Dialyzer. Development compilation passed with warnings as errors. The consumer
suite had one scheduling-sensitive save-announcement failure, preserved under
`checks/consumer-timing-failure.log`; its isolated rerun passed. The test now advances
the pause state explicitly instead of relying on 25 ms of scheduler slack.
See [qualification audit](qualification-audit.md) for final consumer/release results
and the exact tested source hashes.

The later [pending-response interruption fix](interruption-fix-20261003/README.md)
retains regression checks, upstream cancellation evidence, and Grok + Legion
WebRTC correction attempts, including an initial-input failure. It addresses the
adapter's stale continuation deadline and late response acceptance during speech.

## Reproduction

Use a temporary Python environment with `websockets==15.0.1`, macOS `say` (Samantha),
and `ffmpeg`. The Python harness obtains the existing Keychain credential privately
when `XAI_API_KEY` is absent. Each run requires a new output file and has a 45-second
event-loop deadline plus bounded connection/authentication setup.

```sh
python scripts/grok_protocol_pilot.py --scenario pending --reasoning high --output /tmp/grok-pending.json
python scripts/grok_protocol_pilot.py --scenario correction --followup-delay 3 --codec pcmu --reasoning none --output /tmp/grok-correction.json
python scripts/grok_protocol_pilot.py --scenario interruption --reasoning high --output /tmp/grok-interruption.json
python scripts/grok_protocol_pilot.py --scenario independent --backend-delay 25 --followup-delay 3 --reasoning high --output /tmp/grok-independent.json
PARLORA_PROVIDER=grok python3 scripts/with_keychain.py mix run scripts/grok_live.exs /absolute/mono24k.pcm
PARLORA_PROVIDER=grok GROK_REASONING_EFFORT=none python3 scripts/with_keychain.py mix run scripts/grok_live.exs /absolute/mono8k.pcmu --pcmu
PARLORA_PROVIDER=grok MIX_ENV=test python3 scripts/with_keychain.py mix run scripts/grok_interruption_live.exs /absolute/mono24k-stop.pcm
```

Each JSON records the exact probe script hash. Early attempts predate additions to
the harness; do not assume they were emitted by the current script. Production
adapter logs describe a working implementation checkout, not a released package.
