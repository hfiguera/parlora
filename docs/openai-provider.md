# OpenAI voice provider

`Parlora.Providers.OpenAI` connects to **GPT-Live** over WebSocket with client
backend delegation. The application supplies credentials explicitly:

```elixir
provider: {Parlora.Providers.OpenAI,
  api_key: key,
  voice: "marin"}
```

The adapter supports mono PCM16LE at 24 kHz and G.711 μ-law at 8 kHz. Session
instructions and history are supplied through `Parlora.start_session/1`.
The supported models are `gpt-live-1.1` (the default) and `gpt-live-1`; other
OpenAI model IDs are rejected. `Parlora.Providers.OpenAI.default_model/0` returns
the current default. To retain 1.0 explicitly:

```elixir
provider: {Parlora.Providers.OpenAI,
  api_key: key,
  model: "gpt-live-1",
  voice: "marin"}
```

## GPT-Live-1.1 assessment

OpenAI [released GPT-Live-1.1 on November 19, 2026](https://developers.openai.com/api/docs/changelog).
Its documented improvements are more accurate speech
transcription, better pronunciation, and more consistent accents and voices across
languages. Better transcription could improve the caller context used by Parlora's
application policies; measure names, dates, numbers, corrections, and language
switching on your own calls before relying on that benefit.

Both models accept audio/text and produce audio/text through the same Live endpoint.
Parlora retains client delegation, both supported audio formats, context
acknowledgments, and output recovery. Replacement sessions preserve the selected
model. This selection is local to the OpenAI adapter; it does not change other
providers or select a different backend model.

The [prompting guide](https://developers.openai.com/api/docs/guides/live-prompting#recommended-prompt-structure)
recommends plain-language handoffs for 1.1, for example:

```text
Delegation policy:
Backend tools:
- Appointments: check availability and create, change, or cancel bookings.
Delegate to the backend when the caller requests an appointment change.
Do not delegate when asking for missing information or repeating a current result.
Delegate before giving an answer that depends on backend work. Do not guess results.
```

For `gpt-live-1`, the guide instead uses `Generate <|SpawnThinking|>` and
`Do not generate <|SpawnThinking|>`. Supply the model-appropriate instructions
through `Parlora.start_session/1`; the adapter preserves application prompts exactly.
BookingDesk selects the matching OpenAI policy from its provider options. Its
default uses plain language; `provider_options: [model: "gpt-live-1"]` restores
the 1.0 handoff wording. Other providers keep their existing prompts. Applications
with their own 1.0 prompts should update their handoff wording when adopting 1.1.

As of November 23, 2026, both models cost **$0.05 per active minute**, plus separate
backend/tool usage. They have separate concurrent-session limits; verify 1.1 access
and capacity in your organization before rollout. The new **$0.02 per standby
minute** feature applies to provider-side WebRTC sessions and is also available on
1.0. Parlora's browser channel uses WebRTC with the caller, but its OpenAI provider
connection uses WebSocket, so that feature requires a new provider transport and
lifecycle integration. Muting input does not enable standby. See
[session management](https://developers.openai.com/api/docs/guides/live-conversations#managing-idle-sessions).

**Default validation:** the November 23, 2026 live comparison passed for both
models over PCM and PCMU, including delegation, order corrections, English/Spanish
transcripts, output recovery, and graceful close. BookingDesk's full recorded-caller
workflow also passed with 1.1, including explicit approval, exactly one booking,
and a simulated reminder. These results support adopting 1.1 as the OpenAI default;
they do not establish a measured voice-quality or latency advantage. Continue to
evaluate pronunciation, noisy calls, and concurrency on your workload, and retain
`model: "gpt-live-1"` as a rollback. Provider selection and backend models are unchanged.

## Voice selection

The default named voice is `"marin"`. Use a different named voice, such as
`voice: "cedar"`, or a saved custom voice:

```elixir
provider: {Parlora.Providers.OpenAI,
  api_key: key,
  voice: %{id: saved_voice_id}}
```

`%{"id" => saved_voice_id}` is also accepted. A custom voice map contains only
`id`, with a nonempty string value. The provider validates project access to the
voice; Parlora does not substitute a named voice if the selection is rejected.

Create and store the voice in your application or OpenAI's voice Playground.
Voice creation is separate from session startup. For voices generated from prompts,
include the original description in the session's `instructions`. Start a new
session to change voice. Output recovery preserves the selected voice and
instructions.

## Audio and context delivery

The provider has a two-second receive reservoir with a three-second local
residence limit. `start_session/1` applies these defaults in the pipeline's format.
This storage absorbs bursts of generated audio; it does not add a two-second startup
wait. Channel playback buffering is configured separately.

Context acknowledgments confirm provider acceptance, not speech or playback.
The `command_ack_timeout_ms:` option defaults to 30,000 ms. If a pending command
remains unacknowledged, the provider fails and closes; uncertain commands are not
automatically replayed. This timeout does not apply to ordinary caller silence.

## Output recovery

Output overflow or stale generated audio can trigger bounded replacement of the
voice transport while retaining the caller channel and backend work. Audio input
during the unavailable interval is discarded, so the caller may need to repeat
speech. Backend results wait for fresh caller input to be interpreted before
being announced; recovery never retries a business operation.

Observe `Parlora.status/1` for `output_recovery` and handle session failure and
closure. A session can remain ready while its voice connection is being recovered;
readiness does not promise uninterrupted audio. If replacement fails, the session
closes. Offer a reconnect path and reconcile uncertain operations before retrying.

## Credentials and diagnostics

Load the key in your host's runtime configuration and pass `api_key:` explicitly.
An opt-in `diagnostic_sink: pid` receives bounded reports about provider connection
closure. These reports can include caller audio and text. It is disabled by
default; keep that receiver and its data private.
