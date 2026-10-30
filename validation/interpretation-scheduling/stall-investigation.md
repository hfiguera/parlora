# Longer-workflow stall investigation — 2026-10-29

OrderDesk is the example application used for this validation. The production
code changes in this follow-up affect only `Parlora.Providers.Phonic`.
Other provider adapters, the session coordinator, OrderDesk's policy, JEV model
(`jev-1.13.0`), confidence thresholds, and confirmation rules are unchanged.

## Confirmed causes

### Completed late Phonic association lost its continuation

The first reproduction completed the corrected order-124 backend request and
received Phonic's processing acknowledgment. At 22.366 seconds the adapter sent
`generate_reply`. The model requested the result again and spoke a waiting
acknowledgment. At 25.603 and 25.605 seconds the application associated two late
calls with that completed task and supplied the verified result. No new reply
was requested, and the run waited until its 170-second deadline.

With `wait_for_response: false`, a tool output adds context without requesting
speech. `resolve_delegation` previously requested continuation only for rejection;
an association could therefore arrive after the original continuation had been
consumed. Provider processing acceptance did not establish a spoken answer.

The adapter now requests continuation for a completed association whose current
result was submitted. Identical associated results can request continuation only
once per caller turn. This prevents different tool IDs from creating a reply loop
while allowing the caller to ask for the same result in a new turn. Pending,
stale, and non-speakable results do not acquire this continuation. Existing caller
speech, generated speech, audio drain, and output-clear gates still apply.

### Phonic tool-only turn left an automatic speech wait armed

A repeat with only the first fix exposed another ordering. The caller finished
at 23.611 seconds; the model returned a tool call at 23.846 seconds. Its completed
association was supplied at 23.950 seconds and processed at 24.020 seconds. The
model emitted no assistant speech boundary. The adapter nevertheless retained
`auto_response_pending: true`, blocked the queued continuation, and eventually
failed with `response_timeout`.

A valid new tool call after caller speech is now treated as response progress.
It clears that automatic-response wait and its deadline. It does not immediately
request generation: the later application result or association supplies output
and requests continuation. No backend retry is involved.

### Gemini clarification was valid but the harness required punctuation

Another reproduction reached clarification successfully. Gemini said “Please
state the complete instruction you'd like me to add for delivery.” The harness
required `?`, so it supplied no prepared answer and timed out. It now accepts a
request for delivery wording phrased as a question or an imperative. The business
assertions still require clarification before two drafts, a refusal, and exactly
one explicit persisted save.

The older Gemini **items** timeout was not reproduced in the follow-up successful
runs. Its original capture lacks provider wire messages and final delivery state.
The punctuation finding does **not** explain that separate attempt, and no Gemini
adapter fix or root-cause claim is made for it.

## Deterministic proof

From the repository root:

```sh
# Expected failure: load the pre-fix adapter into this test VM only.
MIX_ENV=test mix run validation/interpretation-scheduling/replay_phonic_before.exs

# Expected success: current adapter and the same tests.
mix test test/phonic_adapter_test.exs test/phonic_session_test.exs --warnings-as-errors
```

The replay pins the adapter to `7616fa5` without changing checkout/build files.
It produces **23 passes and three failures**: the late-association callback
sequence, the tool-only-turn sequence, and the real-session late-association
regression. The current adapter passes **all 26 tests**. The session regression
also verifies exactly one backend job. Additional assertions cover duplicate
association suppression, a fresh caller turn requesting the same result, and
excluding pending/stale/non-speakable outcomes.

The full library suite passed **587 checks** (six properties and 581 tests; three
hardware/live/stability checks excluded). OrderDesk passed **248 tests** against
the refreshed package. Its browser JavaScript tests passed **3/3**.

## Live evidence and limits

See [compact evidence](stall-investigation-summary.json) for every attempt,
including the failed reproduction, the partial-fix failure, app-baseline runs,
and a Gemini connection that closed during startup before any caller input.
All attempts used the same generated PCM clips and isolated in-memory stores.

| Adapter | Full workflow outcomes with the final relevant changes |
| --- | --- |
| Phonic | 3/3 passed, all 12 assertions each |
| OpenAI | 2/2 passed, all 12 assertions each |
| Grok | 2/2 passed, all 12 assertions each |
| Gemini | 3 passed all 12 assertions; one additional connection closed during startup |

The Phonic passes include completed late associations during correction and item
lookup. Assertions cover a correction
while the original job is pending, discarded stale results, the correct item
lookup, clarification, draft refusal, six backend operations without duplicates,
and exactly one explicitly confirmed save with spoken confirmation.

These results qualify this tested workflow. They do not establish reliability
across all conversations, channels, service conditions, or physical playback.
At the time of this investigation, Phonic remained an accepted **experimental
provider**. The [current acceptance decision](../phonic/README.md#acceptance-decision)
records its subsequent promotion to supported status. The unexplained historical
Gemini items attempt remains recorded rather than being declared fixed.

## Reproduce with provider messages

Refresh OrderDesk's vendored package after a library change, then run from
`examples/order_desk` using the existing Keychain launcher:

```sh
PARLORA_PROVIDER=phonic ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
  python3 scripts/with_keychain.py mix run --no-compile \
  ../../validation/interpretation-scheduling/trace_live.exs \
  /tmp/orderdesk-scheduling-clips /tmp/orderdesk-phonic-traced.json
```

`trace_live.exs` records synthetic session events and parsed Phonic/Gemini control
messages and state flags. Audio and API keys are omitted. Detailed reports remain
ignored by Git. Failed workflows still save their traces and return a nonzero
exit status. `ORDER_DESK_REPLAY_REVISION=53474ca` loads the three earlier OrderDesk
interpretation modules into that VM for an app-baseline comparison; it does not
restore the checkout or replace the provider implementation.
