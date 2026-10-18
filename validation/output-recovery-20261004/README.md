# GPT Live burst storage and voice transport recovery — 2026-10-04

GPT Live now uses a 2-second receive reservoir and a 3-second residence limit.
The adaptive playback floor remains 120 ms. Capacity/residence exhaustion clears
the old output through the playback barrier and replaces the voice connection;
it does not restart the caller channel or backend. Backend results wait for fresh
caller speech and interpretation. Microphone audio lost during reconnect is
counted, and the assistant asks the caller to repeat.

## Captured-call replay

`ended-call-envelope.json` contains the complete numeric arrival envelope available
from the call that ended at 16:13:16 on October 4, plus rendered 10 ms peak levels.
It contains no transcript or recorded PCM. `replay.exs` synthesizes PCM from those
levels, conservatively represents the unrendered tail as nonquiet audio, and tests
all ten 1 ms offsets of the playback clock against both receive profiles.

| Profile | Capacity failures | Peak receive storage | Source integrity | Initial wait |
| --- | --- | --- | --- | --- |
| Previous 700 ms | 10/10 | 700 ms | Interrupted by overflow | 100–109 ms |
| Current 2,000 ms | 0/10 | 740 ms | All 1,910,400 bytes, in order | 100–109 ms |

`replay.json` retains all results and gap classifications. This checks preservation
and bounds through the captured arrival sequence. It does not establish physical
audio quality or predict provider output after the original failure.

```sh
MIX_ENV=test mix run validation/output-recovery-20261004/replay.exs
```

## Forced live recovery

`live.exs` connects to the real GPT Live API using a memory caller and fake backend,
then inserts 20 ms of expired receive audio to exercise the residence boundary.
The actual replacement TLS/WebSocket connection completed in **733 ms**. Session,
channel, provider adapter, backend and pipeline identities were preserved, the
session stayed ready, and pending results remained held for caller resumption.
The replacement produced 20 audio frames. Numeric evidence is in `live.json`.

This probe makes billable API requests. It requires `OPENAI_API_KEY`; on this Mac
the existing development Keychain loader can supply it without printing the key:

```sh
MIX_ENV=test python3 scripts/with_keychain.py mix run validation/output-recovery-20261004/live.exs
```

The probe uses no physical microphone, browser or carrier. It proves transport
replacement and process continuity, not that a person heard the recovery notice.

## Automated and packaged checks

`ci.log` records compilation with warnings treated as errors, the full ExUnit and
property suite, native checks, Credo, duplication checks, Credence and Dialyzer.
`captions.log` records 17 passing browser caption tests, including recovery epochs.
`consumer.log` records source-package materialization, 203 passing standalone
OrderDesk tests, production release compilation and release smoke checks with
Sagents installed. `consumer-final.log` revalidates the final adapter changes in
that packaged consumer. `verification.json` summarizes the final results.

The recovery tests cover capacity/age exhaustion, stale timers and sockets, real
local connector ownership and handshake, finite reconnect failure, output
suppression, held and corrected results, duplicate completion, early
delegations, timestamp rebasing and incomplete usage. A second recovery retains
unsent updates and their acknowledgment tracking; transport remapping preserves
logical update identity rather than resending an already admitted update.

One intermediate full-suite run failed the existing LocalAudio test's fixed 30 ms
capture wait while a consumer native build was running. No LocalAudio code or test
was changed; the final full-suite run is recorded separately in `ci.log`. The timing
assertion remains sensitive to scheduling pressure.

## Limits

A finite reservoir cannot preserve unlimited faster-than-playback generation.
Hard limits remain bounded and observable. Successful overflow recovery retains
the call; replacement transport failure still has a five-second deadline. Clearing
cannot retract audio already transmitted beyond the channel's declared scope.
Recovery never resubmits backend work. Application policy continues to own repeated
requests, corrections and authorization for business actions. Usage from an
interrupted transport remains explicitly incomplete.

See [the recovery contract](../../docs/output-recovery.md) for the API and lifecycle.
