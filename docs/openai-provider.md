# OpenAI voice provider

`Parlora.Providers.OpenAI` connects to **gpt-live-1** over WebSocket with client
backend delegation. The application supplies credentials explicitly:

```elixir
provider: {Parlora.Providers.OpenAI,
  api_key: key,
  voice: "marin"}
```

The adapter supports mono PCM16LE at 24 kHz and G.711 μ-law at 8 kHz. Session
instructions and history are supplied through `Parlora.start_session/1`.
The supported model is `gpt-live-1`; other OpenAI model IDs are rejected.

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

Output overflow or stale generated audio can trigger bounded replacement of the
voice transport while retaining the caller channel and backend work. The caller
may need to repeat speech during that interval. See [output recovery](output-recovery.md)
for application behavior and failure handling.

## Credentials and diagnostics

Load the key in your host's runtime configuration and pass `api_key:` explicitly.
An opt-in `diagnostic_sink: pid` receives bounded reports about provider connection
closure. These reports can include caller audio and text. It is disabled by
default; keep that receiver and its data private.
