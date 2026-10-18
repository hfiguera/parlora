# Recorded speech in the internal browser — September 17, 2026

The OrderDesk consumer now has an opt-in recorded input for unattended browser
voice tests. It is application-only: no Parlora API or production behavior changes.
Setup and limits are documented in
[the consumer instructions](../../examples/order_desk/APPLICATION.md#recorded-voice-testing-development-only).

## Live evidence

Tested from Codex's internal browser on macOS at `http://127.0.0.1:4001`, with
real WebRTC, GPT-Live-1, TypeSafe, Jido, and an isolated SQLite database. Synthetic
speech came from macOS Samantha via `say`, encoded as 24 kHz mono PCM WAV. Web
Audio fed the clips into the outgoing WebRTC track; no microphone was opened,
no transcript was injected, and the draft's Reject button was never clicked.

The first setup call created a draft but its UI visibility was disrupted by two
local servers sharing the `localhost` cookie namespace. That call was closed.
The evaluated call used the separate `127.0.0.1` hostname to avoid cookie collisions.
Changing ports alone does not isolate cookies. No original database records changed.

The evaluated call ran approximately 21:36:37–21:38:27 (local log time):

| Scenario | Result | Evidence |
| --- | --- | --- |
| Request reception draft for order 124 | Pass | One completed/accepted job; pending draft appeared in UI and SQLite |
| “No, don't save that. Keep the original instructions.” | Pass | Second job completed/accepted; draft rejected; confirmation control removed |
| Wait after the refusal | Pass | At 21:37:53 interpretation settled; both delegations claimed; no clarification requested |
| Saved instructions | Pass | Test order 124 stayed empty/version 1; zero saved changes |
| New “What items are in order 123?” request | **Failed** | At 21:38:06 policy requested clarification; at 21:38:18 interpretation unresolved, new delegation pending, no third job |
| Disconnect/cleanup | Pass | Input controls disabled/reset; test server `/health` returned zero active sessions |

The failed items follow-up remains open. The assistant said it was checking items,
then asked whether the caller meant lookup/status/items/delivery/refusal. This run
does not establish its root cause and is not an all-scenarios pass. The earlier
scripted TypeSafe replay passed that transition, showing why actual browser audio
coverage is useful.

No provider output overflow or browser console warning/error was observed in the
evaluated call. Startup capture discards and playback-starvation observations were
present; these include silence/pauses and do not establish audible choppiness.
No opening greeting appeared in the evaluated call's captions before the first
clip; readiness was reached, and the assistant responded to the clip. The first
setup call did include a greeting. This does not establish a greeting guarantee.

Evidence: [captions](captions.txt), [events and work status](call-events.txt), and
[structured results](results.json). These are synthetic demo utterances only.
The original order remained `123 main st`, version 2, with its one prior saved
change. The isolated test database and generated WAVs are not committed.

## Automated checks

- 36 consumer tests passed on macOS and Linux, including disabled routes,
  fixed clip allowlist and production configuration gating.
- Three Node lifecycle tests passed: clip serialization/mute/cleanup, disconnect
  during asynchronous resume, and oversized-duration rejection.
- JavaScript syntax, Elixir formatting/compilation and whitespace checks passed.
- Scoped UI review passed for the developer disclosure at default and 390 px
  widths; normal UI styles were preserved. No design-detector findings.

Run the lifecycle checks from the Parlora checkout:

```sh
node --test validation/browser/recorded_input_unit.cjs
```

This proves a repeatable browser input mechanism and the recorded refusal path.
It does not replace deterministic fragment-timing tests, human microphone testing,
physical Linux audio checks, or evaluation of perceived assistant playback.

## Additional manual cases

See [delivery correction and interruption/reconnect](remaining-cases/README.md)
for the later live browser runs, including the successful save/reconnect checks
and the remaining interruption-interpretation and caption-reset rough edges.
