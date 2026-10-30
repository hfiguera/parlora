# Phonic-1 validation

These probes use generated speech and synthetic backend facts. They establish
wire and adapter behavior, not human conversation quality, physical playback,
PSTN quality, production latency, or broad reliability. No credentials or raw
audio are written into reports. Generated detailed reports remain ignored by
Git; `summary.json` is the compact checked-in evidence.

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
