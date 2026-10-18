# Grok voice provider

`Parlora.Providers.Grok` connects to **grok-voice-3.0** with client backend delegation.
Reasoning defaults to **high**:

```elixir
provider: {Parlora.Providers.Grok,
  api_key: key,
  reasoning_effort: :high,
  voice: "eve"}
```

Load the key in your application and pass it explicitly. `reasoning_effort:`
accepts `:high` or `:none`. Other model IDs are rejected. Readiness waits for the
provider's configuration acknowledgment to match the requested model and
reasoning effort; a WebSocket connection alone is insufficient.

Session instructions and bounded text history are supplied through
`Parlora.start_session/1`. History seeds conversation text and does not replay
backend work.

## Audio and interruption

The adapter directly supports mono PCM16LE at 24 kHz and G.711 μ-law at 8 kHz.
Input runs continuously, including silence while idle or locally muted. Muting
is a local capture gate, not a disconnect or billing pause.

`start_session/1` automatically applies a reservoir for generated audio with
20 seconds of capacity and a 21-second local residence limit, scaled to the
pipeline format. This is separate from the channel playback cushion. Override
it with explicit `limits:` when appropriate. Playback remains at real-time speed;
interruptions clear retained output. Overflow, stale output, transport failure,
or an expired interruption barrier fails the provider explicitly.

Caller transcripts are finalized after audio commitment. Assistant transcript
deltas retain their provider segment IDs. Transcript timestamps are unavailable.
Provider response completion describes generation, not downstream playback.

## Context and work

The attached function is `delegate_to_backend`. The context policy and backend
own task interpretation, authorization, revisions, confirmation, and execution.
Model arguments do not grant business permissions.

Results for superseded or cancelled work are checked before delivery. Explicit
continuation waits for current caller speech and relevant pending function
outputs. Other caller turns can continue while backend work remains pending.

| Capability | Behavior |
| --- | --- |
| Speakable context | Supported |
| Quiet context and changed system instructions | Unsupported after startup |
| Context delivery | Local socket submission, outcome `:unconfirmed` |
| Uncertain transmission | Outcome `:unknown`; no automatic retry |
| Input mute | Local capture gate |
| Usage | Not advertised |
| Socket failure | Closes the session; no transparent resumption |
| Close | Releases resources; provider finalization remains unconfirmed |

## OrderDesk selection

Supply `XAI_API_KEY` in the installed example and run:

```sh
PARLORA_PROVIDER=grok GROK_REASONING_EFFORT=high scripts/browser.sh
```

The same configuration selects Grok for local audio and phone launchers. The
backend selection and any backend text model are independent of the voice model.
See [OrderDesk](../examples/order_desk/README.md) for application credentials.
