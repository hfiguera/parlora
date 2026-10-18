# Standard Gemini 3.8 Live pivot — 2026-09-24

The production Gemini provider now selects `gemini-3.8-live`. Seven realistic
OrderDesk browser scenarios passed, and a separate twelve-second lookup test
verified that a superseded result arriving late was excluded from speech. OpenAI
remains the application's default; `PARLORA_PROVIDER=gemini` selects standard Live.
This is a bounded synthetic-speech qualification, not full production parity.

## Implementation differences

- Removed thinking configuration from setup, local examples, and OrderDesk.
  Explicit `thinking_level` / `thinking_config` library options are rejected locally.
  The application no longer reads `GEMINI_THINKING_LEVEL`. Extended Thinking is not
  accepted by the production adapter; the standalone SDK diagnostic still compares
  both models and old evidence remains intact.
- Standard `turnComplete` marks provider idle in the absence of an explicit
  interaction status. Explicit IN_PROGRESS or IDLE wins. A generation-complete
  event alone does not imply idle. Receiving continues after completion, and
  pending backend calls independently prevent unsafe reconnection. Incoming audio
  revokes the idle recovery boundary even if its caption has not arrived.
- Retained NON_BLOCKING delegation. Function responses now carry top-level
  `scheduling: "WHEN_IDLE"`, so the provider can announce the result after its
  current speech. The SDK wire-format audit verifies the complete declarations and
  response body. Scheduling is not placed inside application result data.
- Preserved bounded calls, revision handling, deduplication, cancellation, stale
  result exclusion, secure credentials, unavailable caption timestamps and raw
  usage metadata. No provider acknowledgment is manufactured.
- Generic quiet updates and live system-instruction changes remain unsupported.
  SILENT scheduling for a particular function response would not establish those
  broader capabilities. Greetings and save announcements retain their speakable,
  unconfirmed-submission path.

Sources: [standard model](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live),
[tool protocol](https://ai.google.dev/gemini-api/docs/live-api/tools), and
[SDK serialization audit](schema-audit.json). The SDK and live API confirm
WHEN_IDLE is a function-response field, despite inconsistent examples across docs.

## Audio issue found and fixed

The first production-adapter order probe emitted a valid tool call and began the
correct reply, then exceeded the original 700 ms provider receive buffer
([original failure](adapter-order.log)). Standard Live can generate audio faster
than playback consumes it.

`Gemini.audio_limits(format)` supplies an explicit finite 10-second receive
capacity and 11-second receive-age limit, scaling to 480,000 bytes for PCM24 or
80,000 bytes for PCMU8. OrderDesk and the root local example apply it only to
Gemini, preserving application overrides. The pipeline queue remains 200 ms and
all queued provider audio is discarded at an interruption. Exceeding capacity or
age still fails explicitly. This trades some queued-speech tolerance for burst
continuity; it is not an unbounded buffer or a zero-latency guarantee.

[Buffered PCM lookup](adapter-order-buffered.log) and [PCMU lookup](adapter-pcmu.log)
passed with the actual API, delayed fixture results and spoken order 124 / Friday.
The PCM probe took 26.8 seconds overall, including setup/input/three-second tool
delay; PCMU took about 9 seconds. This small sample does not establish typical
latency. Raw PCMU transport/conversion is verified; no Twilio/Telnyx PSTN call or
physical listening test was performed.

## Live task evidence

[OrderDesk report](orderdesk/report.json): **7/7 passed** using synthetic macOS
Samantha speech through Chromium/WebRTC, the real provider, TypeSafe interpretation,
Jido, and fresh isolated SQLite fixtures:

1. Order 124 status, correct stored facts, no duplicate lookup.
2. Missing order number followed by clarification.
3. Order 123 corrected to 124, current answer delivered.
4. Follow-up item lookup, correct stored items.
5. Voice-created draft and explicit browser-confirmed save.
6. Browser disconnect/reconnect, pending draft preserved, fresh read, no replay.
7. Browser-created/confirmed save announced accurately.

The four-second lookup in case 3 finished just before the correction was processed;
that pass alone did not prove exclusion of a late result. A separate
[slow correction report](slow-correction/report.json) uses twelve seconds for order
123 and one second for 124. At correction, 123 was still submitted but no longer
current. It subsequently completed with `delivery: stale` and no result command.
After waiting thirteen additional seconds, there were still only two jobs and the
spoken answer contained only the current order's facts.

The [initial slow test](slow-correction-initial/report.json) is retained as failed:
its assertion incorrectly demanded immediate `cancelled` status. Backend
cancellation is advisory. The revised test checks the promised contract: supersede
while work runs, exclude its late result, and do not replay work. This was a test
expectation correction, not a change that forces backend termination or hides
an actual stale answer.

[OpenAI control](openai-control/report.json): **2/2 passed** for status lookup and
browser-save announcement on the updated application. Earlier six-case OpenAI and
Extended Thinking results remain separate historical evidence, not a simultaneous
full benchmark. No cost or general speed comparison is inferred from these runs.

## Interruption and resumption

[Interruption](interruption.log) used the production session and pipelines with
an in-memory channel and the real API. It cleared at epoch 1 with zero stale
frames observed after clear, produced fresh Hello audio, and observed 423 ms from
input start to clear. This measures the software clear boundary, not what a human
heard or physical output latency.

[Provider resumption](resumption.log) used a real server handle with test-injected
GoAway at a safe idle boundary. The adapter reconnected and recalled reference 124.
This is separate from the browser reconnect case, which starts a fresh session.
It does not prove natural GoAway behavior, durable/exactly-once recovery, or
long-session context compression. Continuity remains reported as unverified until
application evidence supports a stronger conclusion.

## Validation scope

[checks.json](checks.json) records current source hashes and platform checks.
The root suite contains 271 tests/properties, and the standalone OrderDesk suite
contains 155 tests. Required native tests, format, Credo, clone detection, Credence,
and Dialyzer are included. Release checks verify Gemini selection with a dummy
credential, load the actual native resampler, and run offline application smoke
work; they do not make live API calls with the dummy credential.

The larger-buffer regression initially assumed a large WebSocket message would
arrive in one TCP read, which failed on Linux. It now fills the queue with bounded
messages before verifying that interruption discards the entire two-second burst.
A separate Mac validation rerun encountered stale Intel NIF artifacts; forcing an
Apple Silicon rebuild corrected the local build environment. These initial failures
are distinguished from the verified final checks.

Remaining limits: small synthetic sample, no human/accent qualification or physical
PSTN call, no natural GoAway or compression endurance test, no proof of server-issued
function cancellation in this standard-model campaign, and no comprehensive latency
or billing comparison. Application-owned stale-result protection is demonstrated.
