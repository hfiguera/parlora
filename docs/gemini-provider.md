# Gemini voice provider

`Parlora.Providers.Gemini` connects to **gemini-3.8-live** with client backend
delegation. It uses standard Live; thinking configuration is unsupported.

```elixir
provider: {Parlora.Providers.Gemini,
  api_key: key,
  voice: "Puck"}
```

The host loads the key and passes it explicitly. Session instructions and bounded
text history come from `Parlora.start_session/1`. The supported model is fixed to
`gemini-3.8-live`. `api_version:` accepts `:v1beta` (default) or `:v1alpha`.
Do not pass `thinking_level:` or `thinking_config:`.

## Audio and lifecycle

Both common pipeline formats are supported: mono PCM16LE at 24 kHz for local or
browser audio, and G.711 μ-law at 8 kHz for phone audio. The adapter handles
Gemini's input/output conversion internally.

Input runs continuously, including codec silence while idle or locally muted.
Muting does not disconnect the session. Readiness requires `setupComplete`.
Socket failure, startup expiry, receive overflow, or stale audio fails explicitly.
Close unused sessions rather than assuming an idle connection is free.

`start_session/1` automatically applies Gemini's reservoir for generated audio:
10 seconds of capacity and an 11-second residence limit, scaled to the selected
format. Channel playback buffering remains separate. Explicit `limits:` override
the defaults. Larger receive storage does not change playback speed or startup
buffering; interruptions clear retained output.

## Context and work

The provider exposes one non-blocking function, `delegate_to_backend`. Its arguments
request interpretation; your context policy and backend determine the authorized
operation and result. Corrections create or supersede task revisions through that
policy. Cancelling a provider call does not reverse an external business action.

| Capability | Behavior |
| --- | --- |
| Speakable context | Supported |
| Quiet context and changed system instructions | Unsupported after startup |
| Context delivery | Local socket submission, outcome `:unconfirmed` |
| Input mute | Local capture gate |
| Speech/activity | Provider state reported separately from playback |
| Usage | Metadata reported by the provider; no invented final bill |
| Socket resumption | Bounded provider resumption when available; does not replay business actions |

A successful context write is not a provider acknowledgment. Assistant transcript
groups have locally generated segment IDs; timestamps are unavailable. Provider
speech completion also does not establish that downstream audio has finished
playing. Keep application announcements brief and coordinate them with current
speech/task state.

## OrderDesk selection

In the installed example, supply `GEMINI_API_KEY` and run:

```sh
PARLORA_PROVIDER=gemini scripts/browser.sh
```

The same selection applies to its local and phone launchers. Browser and phone
workflows also need the application's TypeSafe credential. See
[OrderDesk](../examples/order_desk/README.md) for setup.
