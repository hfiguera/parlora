# Phonic-1 validation

These probes use generated speech and synthetic backend facts. They establish
wire and adapter behavior, not human conversation quality, physical playback,
PSTN quality, production latency, or broad reliability. No credentials or raw
audio are written into reports. Generated detailed reports remain ignored by
Git; `summary.json` is the compact checked-in evidence.

Normal session closure has a separate [shutdown regression and live-service proof](shutdown.md),
including PCM, mu-law, bounded TLS cleanup, and a synthetic Twilio stream.

## Acceptance decision

Phonic-1 is a **supported provider** in Parlora. Promotion from experimental
status follows regression and live-service proof for result continuation,
duplicate reply coordination, and normal shutdown, plus successful manual
OrderDesk calls through the browser, Twilio, and Telnyx.

The initial experimental acceptance on October 29, 2026 was supported by the
implemented adapter, offline regression coverage, live wire and real-adapter
probes, and a successful manual OrderDesk call. That call handled an order
correction, status and item lookups, delivery instructions, a draft, and a
separately confirmed save. Four backend requests completed; the session recorded
29 interpretation evaluations and zero errors.

The [longer-workflow follow-up](../interpretation-scheduling/stall-investigation.md)
reproduced and fixed two Phonic continuation defects. Phonic and the other three
providers completed repeated live workflows. The report retains failed attempts
and distinguishes a fixed Gemini harness issue from an older unexplained items
timeout. See also the [original results](../interpretation-scheduling/README.md#observed-results-2026-10-29).

The [reply-coordination follow-up](../interpretation-scheduling/reply-coordination.md)
adds coverage for duplicate announcements as well as workflow completion, and
records the Phonic-only scheduling change and stronger live checks.

Linux validation of runtime commit `646313a` passed full `mix ci`: 603 library
checks, all three native bindings, and static analysis including Dialyzer with
zero errors. The standalone packaged OrderDesk consumer passed 248 tests and
its production release smoke test. Three stability tests covered 100 session
cycles and 500 corrections; 11 Python tooling tests also passed. Strict
documentation generation passed after the link correction in `4de4dc1`.

Support covers the documented adapter capabilities and tested workflows.
Reliability under sustained production load and varied network conditions
remains unqualified. Automatic reconnect, initial history, and usage reporting
remain unsupported; see the [provider guide](../../docs/phonic-provider.md).

## Wire probes

Requires macOS `say`, FFmpeg, and `websockets==15.0.1` (the command below uses
`uv` to isolate the Python dependency). The timeout is capped at 60 seconds per
probe, with a 45-second default.

```sh
PARLORA_PROVIDER=phonic python3 scripts/with_keychain.py \
  uv run --with websockets==15.0.1 python scripts/phonic_protocol_pilot.py \
  --scenario correction --output validation/phonic/results/correction-pcm.json
```

Other scenarios: `baseline`, `pending`, `interruption`, and `reconnect`.
`--codec pcmu` tests Phonic's **native** mu-law wire path, not the adapter's
conversion path. `--retention zero` explicitly requests ZDR; the default sends
no retention override, so the provider's default policy applies. Only synthetic
content should be used with this script.

Observed with Phonic-1 on October 29, 2026 (America/Denver):

- PCM24 configuration, caller transcripts, client tools, and explicit result
  continuation worked.
- An unrelated question was answered while backend work remained pending.
- A correction created a replacement tool call before the old result returned;
  only the current supplied fact was announced.
- Caller speech interrupted an active assistant utterance.
- Aborting a connection and reconnecting with `reconnect_conv_id` resumed the
  conversation and produced `conversation_reconnected`.
- Native mu-law configuration was accepted, but neither the default nor the
  lowest documented VAD threshold detected the synthetic caller. The adapter
  therefore uses PCM24 on the wire with internal conversion for mu-law channels.
- Explicit ZDR configuration was rejected by this account with
  `data_retention_not_allowed`.

The official SDK implementations inspected were Node
`ab7a279d71646c952d5764286e3536bfb2f2830d` and Python
`f71ee3bf80b3bcda6b9a0cd5eb0f87ac6f7867d0`. Both reconnecting wrappers skip
sends during reconnection, including tool outputs. The Parlora adapter instead
closes explicitly on transport loss; it does not copy this silent-drop behavior.

## Actual Elixir adapter

Generate a synthetic mono raw clip with an order lookup, then run either:

```sh
PARLORA_PROVIDER=phonic python3 scripts/with_keychain.py \
  mix run scripts/phonic_live.exs /absolute/path/lookup.pcm pcm \
  validation/phonic/results/adapter-pcm.json

PARLORA_PROVIDER=phonic python3 scripts/with_keychain.py \
  mix run scripts/phonic_live.exs /absolute/path/lookup.mulaw pcmu \
  validation/phonic/results/adapter-pcmu.json
```

The first clip must be PCM16LE/24 kHz. The second is mu-law/8 kHz. The adapter
uses PCM24 wire audio for both. Each smoke run is bounded to 45 seconds and
requires generated output audio, a client delegation, submitted backend facts,
the matching provider-processing acknowledgment, and an observed Friday result.
Both formats passed this test with the actual adapter.

## Offline checks

```sh
mix test test/phonic_protocol_test.exs test/phonic_adapter_test.exs \
  test/phonic_audio_test.exs test/phonic_session_test.exs --warnings-as-errors
```

Session tests connect the real Phonic callback implementation to a local
WebSocket fixture and exercise coordinator revisions, stale-result suppression,
provider-result correlation, and whole-session cleanup after socket loss. The
wire fixture never connects to Phonic and uses no real credential.

## Repeated delegation regression

The adapter disables `allow_tool_chaining` while retaining async execution and
`wait_for_response: false`. The baseline and pending wire probes require exactly
one delegation; correction requires exactly two, one for each requested order.
The actual adapter smoke also requires exactly one call.

`order_desk_delegation.exs` exercises the actual OrderDesk policy, TypeSafe
interpretation, Jido backend, SQLite store and Phonic adapter through an in-memory
PCM channel. It requires an isolated `:memory:` database and synthetic PCM16LE,
mono 24 kHz clips named `items.pcm`, `instructions.pcm`, and `draft.pcm` containing:

1. “What items are in order one two four?”
2. “What are the saved delivery instructions for order one two four?”
3. “For order one two four, change the delivery instructions to leave it at reception.”

Generate the clips using macOS `say` and FFmpeg, as in the wire probe. Refresh
OrderDesk's vendored Parlora package before running from `examples/order_desk`:

```sh
PARLORA_PROVIDER=phonic ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
  python3 scripts/with_keychain.py mix run \
  ../../validation/phonic/order_desk_delegation.exs /absolute/path/to/clips \
  ../../validation/phonic/results/no-chaining-orderdesk.json
```

The run is bounded to 100 seconds. It observes two seconds after each answer,
requires one delegation per request and three completed backend operations, and
checks that exactly one review draft exists and voice saved no changes. This
validates application and adapter behavior; it does not exercise browser WebRTC
or establish what a human heard. Compact results are recorded in `summary.json`.

Observed on October 29, 2026 (America/Denver): all three wire scenarios passed
with call counts 1 (baseline), 1 (pending unrelated question), and 2 (original
request plus correction). The corrected result was announced without the obsolete
fact. Actual OrderDesk passed all checks: one call each for items, instructions
and a draft, three backend completions, one review draft, and no voice save.
Before this change, the same three operations in the manual call each produced
20 tool calls. These are bounded observations, not a guarantee of all model behavior.
