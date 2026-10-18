# Grok pending-response interruption fix

The adapter now invalidates an explicit response's start deadline when caller
speech interrupts it. A response that starts late during that speech is cancelled
and discarded without consuming the next automatic caller turn. Discarded audio,
captions, tool calls, and completion events cannot affect the fresh response.
Discard bounds and current continuation deadlines remain enforced.

Production-adapter loopback tests cover both reproduced races and the discard
capacity bound. Core CI passed 361 checks, with three excluded tests; separate
Jido, Sagents, and Legion consumer suites passed 196, 199, and 200 tests. Development
compilation passed with warnings as errors. Exact source hashes and check logs are
retained in [report.json](report.json) and `checks/`.

The direct upstream cancellation probe received `response.done` with status
`cancelled`, then a fresh completed response saying "Hello" with audio. Reproduce
through the private Keychain launcher:

```sh
PARLORA_PROVIDER=grok python3 scripts/with_keychain.py mix run validation/grok/interruption-fix-20261003/cancel-protocol.exs
```

Two immediate-correction WebRTC attempts with Grok HIGH and Legion had one pass
and one failure before the initial order request registered. That failure had no
initial speech-start event and remains in `live-immediate/`. A separate attempt
with a one-second pause before the initial input passed, retained under
`live-settled-input/`. Each passed correction performed exactly the 123 and 124
status reads and announced the current 124 result. Both batches cleaned up to zero
active sessions. These post-fix live traces did not exercise the late-created
response race; the deterministic loopback tests cover that ordering.

Live folders retain reports, synthetic captions, lifecycle traces and the exact
runner variants. The runner uses `validation/acceptance/live.cjs` and the browser
dependencies, and its server uses `trace.exs` through `GROK_TRACE_SCRIPT`. Use a
temporary sibling layout matching `validation/task-pilot` and new output paths to
reproduce; retained `sources` and `consumer_sources` record the tested hashes.

The earlier [investigation](../../legion/grok-correction-stall-20261003/report.json)
is a pre-fix snapshot. Its bug-demonstration tests intentionally assert the old
behavior and should not be used as acceptance tests for this fix. Attribution of
the original historical failed call remains unverified because its provider
lifecycle was not retained. Synthetic probes do not establish human audio quality,
PSTN behavior, long-session stability, or a production success rate.
