> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Session Tokens

> Mint short-lived tokens from your API key for use in browser and mobile clients.

Session tokens are short-lived credentials minted by Phonic on your behalf. They
let client-side code authenticate to Phonic without ever seeing your `PHONIC_API_KEY`.

Use session tokens when your code runs in a browser, mobile app, or any environment
you do not fully control. Use an [API key](/docs/platform/authentication/overview) directly when your code
runs on your own backend.

## How it works

1. Your backend calls `POST /v1/auth/session_token` using your API key.
2. Phonic returns a token of the form `ph_session_...` with a TTL you choose.
3. Your client uses that token to open a conversation WebSocket.
4. The token expires automatically. To extend a session, mint a new one.

## 1. Mint a session token

The endpoint accepts a `ttl_seconds` field between `60` and `3600`. The default is
`300` (five minutes).

It also accepts an optional `conversation_ids` array of 1 to 10 conversation
IDs. A token created with it can observe only those conversations' live audio
and transcript; a token created without it can observe any live conversation in
your organization, and can also start conversations on `/v1/sts/ws`.

```typescript
import { PhonicClient } from "phonic";

const client = new PhonicClient({
  apiKey: process.env.PHONIC_API_KEY,
});

const { session_token, expires_at } = await client.auth.createSessionToken({
  ttl_seconds: 300,
});
```

```python
import os
from phonic import Phonic

client = Phonic(api_key=os.getenv("PHONIC_API_KEY"))

response = client.auth.create_session_token(ttl_seconds=300)
session_token = response.session_token
expires_at = response.expires_at
```

## 2. Use the session token

Pass the token as the `session_token` query parameter when opening the conversation
WebSocket:

```
wss://api.phonic.ai/v1/sts/ws?session_token=ph_session_abc123...
```

This endpoint starts a conversation, so it accepts only a token created without
`conversation_ids`. To observe a call that is already running, create the token
with `conversation_ids` and use it on the
[live conversation WebSocket](/guides/conversations/live-websocket) and its HLS
audio instead.

Session tokens cannot be combined with any other authentication mechanism on the
same request.

## Revocation

Session tokens are stored server-side and can be revoked instantly by Phonic if
needed. In practice, however, the simplest revocation strategy is to keep the TTL
short and let tokens expire on their own.

If you need stateless verification without a round-trip to Phonic, use
[JWTs](/docs/platform/authentication/jw-ts) instead.

## Choosing a TTL

* **Shorter TTLs** reduce the impact of a leaked token, but force clients to refresh
  more often.
* **Longer TTLs** are more convenient, but extend the exposure window if a token
  leaks.

The default of 300 seconds works for most use cases. If a single user session may
include several conversations back-to-back, raise the TTL or have your backend mint
a fresh token before each conversation.