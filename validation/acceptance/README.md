# Six-scenario acceptance runner

From the Parlora checkout, with a generated standalone consumer:

```sh
scripts/acceptance.sh /absolute/path/to/parlora_consumer
```

Default mode runs six deterministic application scenarios with real Parlora,
AppPolicy, Jido, and SQLite, a synthetic audio channel/scripted provider, and
fixture classifier answers. **It makes no API calls.** The child receives empty
OpenAI and TypeSafe credentials. Node.js 22+ and the project's pinned Elixir/OTP
and native toolchain are required. Create a consumer first with
`scripts/consumer.sh /absolute/path/to/new/consumer` if needed.

To additionally exercise the real voice pipeline on macOS:

```sh
npm ci --prefix validation/browser
scripts/acceptance.sh /absolute/path/to/parlora_consumer --live
```

`--live` is the paid-test opt-in. The runner uses Chrome, macOS Samantha synthetic
speech, browser Web Audio, WebRTC, GPT-Live-1, TypeSafe, Jido and SQLite. It uses
existing environment credentials, or the consumer's secure Keychain helper on
macOS. Credentials are never placed in reports or command arguments. The test
does not use your microphone, edit your normal database, connect to the existing
server, or change its recorded clip files. Live speech generation currently
requires macOS; deterministic acceptance also runs on Linux.

The live runner substitutes only the six development audio-fixture responses in
its own browser context. Everything after the outgoing audio track follows the
normal application path. A dedicated loopback test server observes public
Parlora events/snapshots to verify tasks/results, with a test-only read endpoint.
That endpoint and observer are never loaded by normal application startup.

## Coverage

| Scenario | Required assertions |
| --- | --- |
| Repeated corrections | 123 → 124 → 123, final accepted status result targets 123; no unexpected intermediate IDs in the live run |
| Missing number | Clarification before any lookup; number reply resolves 124/out for delivery |
| Different questions | Separate status and items work for 124, with desk-lamp answer |
| Draft then refusal | Exact draft rejected, saved instructions/version unchanged, interpretation settled |
| Correct draft | Both exact texts identified; voice does not save; reject reception and explicitly confirm neighbor once |
| Interrupt/disconnect | Corrected items work verified running before disconnect; fresh session has no inherited work/captions; saved instruction and pending draft survive; fresh desk-lamp result accepted |

The refusal expectation matches the current application: **spoken refusal rejects
the exact draft**. The earlier manual instruction to click Reject after speaking
is obsolete. Spoken approval still never saves a draft. Offline confirmation uses
the same store contract; the live suite clicks the actual browser controls.

Every completed conversation must settle with its delegations claimed. Browser
captions supplement task/delivery and database assertions; captions alone cannot
pass a case. Live interruption checks the playing audio element and assistant
captions, not a human acoustic assessment. Browser and native audio counters may
include silence or startup artifacts; the suite does not claim glitch-free audio.

## Reports, bounds, and cleanup

Each invocation creates a private fresh temporary directory and separate offline
and live databases. `--output /absolute/new/directory` selects a new directory;
existing directories are refused. The runner prints the path and writes:

- `report.json` and `report.md`: overall status, modes and per-case outcomes.
- `offline.json` / `offline.log`: deterministic assertions and failure details.
- With `--live`: `live.json`, per-case JSON state/caption/event evidence, screenshots,
  generated synthetic WAV files, and the isolated server log.

A failed assertion exits nonzero. There are no automatic case retries to turn
flaky outcomes into passes. Each live case has a 150-second observation deadline;
ordinary browser actions and HTTP requests have shorter limits. Sessions retain
Parlora's 180-second server bound. Deterministic execution has a 180-second process
limit. Cases disconnect in cleanup; the runner shuts down its own server process
group. Reports and isolated databases remain for investigation. No service keys,
SDP, ICE candidates/credentials, or raw microphone recordings are included in the
browser evidence. Treat reports as local development artifacts.

CI runs deterministic acceptance on macOS and Linux and uploads its reports.
Paid live mode is intentionally absent from CI. A passing offline report does not
establish live speech recognition/classification quality, physical Linux audio,
external-network behavior, or human-perceived interruption/playback quality.

## Recorded qualification

See [validation results](RESULTS.md). The initial consolidated live run passed
five scenarios and exposed a provider output overflow in the sixth; it is
retained as a failed run, not an all-scenarios pass.
