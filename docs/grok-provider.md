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

## Native conversational settings

All of these settings are opt-in. Omitting them preserves the existing wire
configuration and provider defaults. Apps pass them in the Grok provider tuple:

```elixir
provider: {Parlora.Providers.Grok,
  api_key: key,
  language_hint: "en",
  keyterms: ["Cedarwood", "Dr. Lee"],
  replace: %{"Cedarwood" => "Cedar wood"},
  speed: 1.05,
  idle_timeout_ms: 8_000}
```

| Option | Behavior and validation |
| --- | --- |
| `language_hint` | `nil` or a documented Grok language code, normalized to its canonical casing. Supported codes: `en`, `ar-EG`, `ar-SA`, `ar-AE`, `bn`, `zh`, `fr`, `de`, `hi`, `id`, `it`, `ja`, `ko`, `pt-BR`, `pt-PT`, `ru`, `es-MX`, `es-ES`, `tr`, `vi`. Spanish and Portuguese require a region. Omitted/`nil` leaves automatic detection enabled. |
| `keyterms` | At most 100 nonempty UTF-8 strings, each at most 50 Unicode codepoints. These bias transcription; they are not facts, instructions or permissions. |
| `replace` | Nonempty UTF-8 phrase-to-pronunciation strings. Parlora bounds the encoded replacement map to 65,536 JSON bytes. This is a local configuration bound, not an asserted provider limit. |
| `speed` | Number from `0.7` through `1.5`; the provider default is `1.0`. This controls synthesis speed, not PCM playback rate. |
| `idle_timeout_ms` | Positive integer milliseconds or `nil` to disable. Omitted defaults to disabled. The native server re-engages after silence following its response and re-arms after each response, so it can ask repeatedly. Choose this per application and close inactive calls according to application policy. |

The adapter rejects invalid and unknown options before connecting, and fails
readiness if effective requested settings differ in `session.updated`. The
server may omit empty replacements and a disabled idle timeout.
The model and reasoning acknowledgment checks remain in place. No undocumented
noise-suppression setting, extra audio transport, resumption, or hosted tools are
enabled. See the [official session parameters](https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech#session-parameters).

Pronunciation replacements change spoken audio without changing the provider
transcript. Keep them away from consent wording, phone numbers and confirmation
identifiers unless your application independently verifies the resulting speech.

## Exact application speech

Check `Capabilities.context_update_kinds` for `:verbatim`, then submit through the
session so normal provider-generation and task-revision checks apply:

```elixir
:ok = Parlora.append_context(session, %Parlora.ContextUpdate{
  id: command_id,
  kind: :verbatim,
  content: "Cedarwood Family Clinic, this is Ava. How can I help?",
  provider_generation: Parlora.snapshot(session).provider_generation
})
```

Grok maps this explicit kind to native `force_message` TTS, with
`interruptible: true`. It does not ask the model to rewrite the line or send an
additional `response.create`. Native TTS and configured pronunciation rules
still apply. Supply identifiers in the exact spoken form you need.

Text must be nonblank UTF-8, at most 16,384 bytes. This is a local bound. A
verbatim update cannot resolve a delegation: deliver backend results through
the existing result path first. For result-specific speech, include `task_id`
and `task_revision` from the verified result; a stale update is rejected.

While caller speech, automatic response, generated audio, backend calls or other
responses are pending, admission returns `:backpressure` with
`execution: :never_submitted`. Nothing is queued. Recheck current application
state before retrying; the same rejected ID is available for retry. Once an ID
has been submitted, matching retries never speak it again, even if the caller
interrupted it. Conflicting content with the same ID is rejected.

Submission remains `:unconfirmed`. A completed response is not proof of
physical playback or consent. Readbacks still need the application's separate
fresh caller confirmation. One-word interruptions use the existing clear
barrier. Native idle turns never fabricate caller transcripts or consent.

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
| Verbatim application speech | Native interruptible TTS; idle-provider admission only |
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
