> ## Documentation Index
> Fetch the complete documentation index at: https://docs.rime.ai/llms.txt
> Use this file to discover all available pages before exploring further.

# API authentication

> How to authenticate with the Rime text-to-speech and speech-to-text APIs using a bearer token.

Send your Rime API key as a **bearer token** in the `Authorization` header on every request, from your server. The same key covers text-to-speech and speech-to-text.

On the legacy text-to-speech WebSockets, `/ws` and `/ws3`, a client that cannot set headers may instead pass `?rime_apikey=YOUR_API_KEY` on the connection URL. This puts the key in URLs and proxy logs. Prefer a server-side bridge that sets the header. [WebSocket v1](https://docs.rime.ai/api-reference/coda/websocket-v1.md#connect-and-authenticate) and speech-to-text take the key only in the header. Speech-to-text reads it from `Authorization: Bearer` on the WebSocket upgrade, or from `authorization` metadata on each gRPC call. The [Rime SDK](https://docs.rime.ai/api-reference/sdk/stt.md#connection-and-credentials) sends the key for you.

## Get an API key

> [!WARNING]
>
> An API key can synthesize speech against your account. Keep it on the server and treat it like a password.

1. Sign in to the [Rime dashboard](https://app.rime.ai).
2. In the Rime dashboard, open [**API Tokens**](https://app.rime.ai/tokens).
3. Create a token and copy its value.

## Use the token

This request authenticates with a bearer token and saves the MP3 response to `hello.mp3`:

```bash theme={null}
curl --request POST \
  --url https://coda.api.rime.ai/ \
  --header 'Authorization: Bearer YOUR_API_KEY' \
  --header 'Content-Type: application/json' \
  --header 'Accept: audio/mpeg' \
  --fail \
  --show-error \
  --output hello.mp3 \
  --data '{"speaker":"astra","text":"hello","lang":"en"}'
```

If the key is accepted, you'll hear "hello" when you play `hello.mp3`. If it isn't, `--fail` stops curl with a `401` instead of saving the error text as the file.

Use the same header for the HTTP, WebSocket, metadata, and utility endpoints.

## CLI authentication

The `rime` CLI manages the key locally. Run [`rime login`](https://docs.rime.ai/cli-reference/rime-auth) once, and the CLI stores the key at `~/.rime/rime.toml`. You can also set it with the `RIME_CLI_API_KEY` environment variable.

## On-prem authentication

Caller authentication depends on the deployment. A standalone licensed engine doesn't authenticate callers, so your gateway must. Its `RIME_API_KEY` only authenticates the engine's usage reports to Rime. In an existing API/model pair, the API service accepts the same `Authorization: Bearer …` header, or you can configure `RIME_API_KEY` for the deployment so callers don't need to send it. See [the on-prem quickstart](https://docs.rime.ai/docs/on-prem/quickstart.md) for details.

## Common auth errors

If a request to a `users.rime.ai` endpoint fails authentication, the API returns `401 Unauthorized` with a short plain-text body explaining why:

| Status | Body | Cause |
| :- | :- | :- |
| `401` | `missing headers` | No `Authorization` header was sent. |
| `401` | `empty apikey` | The `Authorization` header was sent with an empty key. |
| `401` | `invalid api key` | The token is not recognized, or it was sent without the `Bearer` scheme. |
| `401` | `invalid subscription` | The token is valid, but its account has neither a valid subscription nor a positive balance. Check billing before regenerating the key. |

Always send the header as `Authorization: Bearer <token>`. The token alone, without the `Bearer ` prefix, is rejected with `invalid api key`.

The model hosts, `coda.api.rime.ai` and `mist.api.rime.ai`, return `401` with an empty body instead. See [Errors from the model hosts](https://docs.rime.ai/docs/errors.md#errors-from-the-model-hosts).

Speech-to-text refuses a missing or invalid key before the stream starts. The WebSocket upgrade gets `401` with an empty body, and gRPC returns `UNAUTHENTICATED`. [Speech-to-text errors and limits](https://docs.rime.ai/docs/stt/errors.md#error-categories) lists every speech-to-text error.

## Related

* [Quickstart: TTS in five minutes](https://docs.rime.ai/docs/quickstart-five-minute.md)
* [Speech-to-text quickstart](https://docs.rime.ai/docs/stt/quickstart.md)
* [API reference index](https://docs.rime.ai/docs/api-reference.md)
* [CLI authentication commands](https://docs.rime.ai/cli-reference/rime-auth.md)


This documentation is built and hosted on [Mintlify](https://mintlify.com), a developer documentation platform.