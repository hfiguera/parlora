# Rime Prism documentation snapshot

These official Rime references were selected for evaluating a direct WebSocket adapter for Parlora. The upstream files are unmodified and keep their site-relative paths. The [manifest](manifest.json) records their source URLs, sizes, and checksums.

## Parlora integration

Select `{Parlora.Providers.Prism, api_key: System.fetch_env!("RIME_API_KEY")}` as the provider in a session using the default PCM16LE format. The optional `:voice` setting selects `astra`, `aurora`, `brando`, or `wawona`. This integration covers English conversations.

The adapter streams 16 kHz input, returns 24 kHz audio, and uses final caller transcripts for policy. Tool-result acceptance confirms that Prism recorded the result. A separate continuation speaks the result when the current tool round is complete. A newer caller turn can supersede that continuation.

On barge-in, the adapter clears the old playback epoch even if Prism finished generating. A channel that implements `clear_output_with_playback/3` can supply the interrupted item's played position. Other channels use Prism's playback estimate.

With a Keychain entry named `parlora-prism-development`, run the local voice example with `PARLORA_PROVIDER=prism scripts/local_voice.sh`.

## Start here

- [Prism overview](docs/prism/overview.md) describes the model, its audio formats, and its language coverage.
- [WebSocket API](api-reference/prism/websocket.md) is the wire reference for the Elixir adapter.
- [WebSocket quickstart](docs/prism/websocket-quickstart.md) provides a minimal audio round trip for a live probe.
- [API authentication](docs/api-authentication.md) explains where to create an API token. The WebSocket API documents how Prism accepts it.

## Conversation and playback

- [Live conversations](docs/prism/live-conversations.md) covers continuous input, turn boundaries, barge-in, and playback reporting.
- [Sessions](docs/prism/sessions.md) covers setup, effective settings, history, and closing a session.
- [Typed turns and nudges](docs/prism/typed-turns.md) explains when the adapter can request speech without new caller audio.
- [Prompting](docs/prism/prompting.md) covers instructions for Prism conversations.

## Tool results and failure handling

- [Tools](docs/prism/tools.md) covers client tool declarations, result delivery, and explicit continuations.
- [Long-running tasks](docs/prism/long-running-tasks.md) explains how newer caller turns and expired tool rounds affect late results.
- [Errors and limits](docs/prism/errors.md) lists connection refusals, scoped errors, and deadlines.

## Cross-reference

- [Prism SDK reference](api-reference/sdk/prism.md) describes the SDK's playback, request, and tool scheduling behavior.
- [Rime SDK implementation](https://github.com/rimelabs/rime-sdk/blob/b3500b696c8c916396c584a3eb8db553fd72fbff/python/src/rimelabs_sdk/realtime/_session.py) shows how the official client matches acknowledgments and tracks tool rounds.
- [LiveKit Prism plugin](https://github.com/livekit/agents/blob/livekit-agents%401.8.11/livekit-plugins/livekit-plugins-rime/livekit/plugins/rime/realtime/realtime_model.py) shows how a host uses measured or estimated playback with the SDK.
- [OpenAI Realtime migration](docs/prism/migrate-from-openai.md) covers protocol similarities and differences. The WebSocket reference distinguishes the OpenAI Realtime and GPT-Live protocols.
- [Rime documentation index](llms.txt) lists the rest of the upstream documentation.
