> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Authentication

> Choose the right authentication mechanism for your use case.

Phonic supports three ways to authenticate requests to the API and the conversation
WebSocket. Pick based on where your code runs and how you manage user identity.

| Mechanism         | Lifetime                           | Who mints it              | Use when                                                                                                           |
| ----------------- | ---------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **API key**       | Permanent                          | You, in the dashboard     | Server-to-server calls. **Never expose to a browser.**                                                             |
| **Session token** | 60s–1h                             | Phonic, from your API key | Browser or mobile clients where you don't want to ship your API key. Simple to revoke.                             |
| **JWT**           | You choose (we recommend ≤ 15 min) | Your own auth system      | Enterprise integrations where you already operate an identity system and need per-user / per-conversation scoping. |

## Quick decision guide

* **Just getting started?** Use an API key. See [Introduction](/docs/get-started/overview).
* **Building a client-side app?** Mint a [session token](/docs/platform/authentication/session-tokens) from your backend and hand it to the browser.
* **Operating your own identity provider?** Issue [JWTs](/docs/platform/authentication/jw-ts) signed with your own key. Phonic verifies them without a round-trip.

## Where to pass credentials

All three mechanisms work on both REST endpoints and the conversation WebSocket.

For REST endpoints, pass credentials in the `Authorization` header:

```http
Authorization: Bearer <PHONIC_API_KEY or JWT>
```

For the conversation WebSocket, pass credentials as a query parameter:

```
wss://api.phonic.ai/v1/sts/ws?session_token=<token>
wss://api.phonic.ai/v1/sts/ws?jwt=<jwt>
```

Browsers cannot set custom headers on a WebSocket handshake, so the query
parameter form exists specifically for client-side use.