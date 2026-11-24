# OpenAI voice provider

`Parlora.Providers.OpenAI` connects to GPT-Live over WebSocket. When a caller asks
for something that needs backend work, GPT-Live can hand the request off to your
application. Your policy decides whether to start the work.

Pass the provider tuple to `Parlora.start_session/1` as the `provider` option.

```elixir
{Parlora.Providers.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")}
```

The adapter supports mono PCM16LE at 24 kHz and G.711 μ-law at 8 kHz.

## Upgrade from GPT-Live-1

Starting in Parlora 0.7.0, OpenAI sessions use `gpt-live-1.1` when you omit
`model`. Parlora 0.6.x defaulted to `gpt-live-1`. Before switching traffic, check
that your OpenAI project has access to 1.1 and enough capacity for your calls.
OpenAI applies separate
concurrent-session limits to the two models. See the [GPT-Live-1.1 model page](https://developers.openai.com/api/docs/models/gpt-live-1.1#rate-limits).

To keep using GPT-Live-1, pass `model: "gpt-live-1"` in the provider tuple and
keep your GPT-Live-1 prompt.

```elixir
{Parlora.Providers.OpenAI,
 api_key: System.fetch_env!("OPENAI_API_KEY"), model: "gpt-live-1"}
```

These are the two model IDs supported by this adapter.
`Parlora.Providers.OpenAI.default_model/0` returns the default. If Parlora replaces
the OpenAI connection during output recovery, it keeps the selected model.

### Update your handoff instructions

For GPT-Live-1.1, describe when to hand off in plain language. List the work your
backend can do and give examples of when to call it. This example assumes the
backend can look up opening hours. Follow [OpenAI's GPT-Live prompting guide](https://developers.openai.com/api/docs/guides/live-prompting#recommended-prompt-structure)
for the full prompt structure.

```text
Delegation policy:
Backend tools:
- Look up the shop's opening hours.
Delegate to the backend when the caller asks when the shop is open.
Do not delegate for greetings or thanks.
Wait for the lookup result before answering with the shop's hours.
```

For GPT-Live-1, use `Generate <|SpawnThinking|>` and
`Do not generate <|SpawnThinking|>` to describe when to hand off. Pass your prompt
as `instructions` to `Parlora.start_session/1`. If you supply your own prompt,
update it when switching models. BookingDesk chooses its handoff wording from
the selected model.

### Session billing

OpenAI bills voice sessions by duration and bills backend model and tool usage
separately. Standby pricing requires a WebRTC connection to OpenAI. Parlora's
OpenAI adapter uses WebSocket even when the caller connects through the browser
channel over WebRTC. See [OpenAI's GPT-Live pricing](https://developers.openai.com/api/docs/models/gpt-live-1.1#pricing).

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
