> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Authenticating with JWTs

> Mint short-lived JWTs in your own auth system and have Phonic verify them, scoped per user and per conversation.

JWT authentication lets your backend mint signed tokens that Phonic verifies without
a round-trip. Each token is scoped to a single end user and a single conversation,
and is valid only until its `exp` claim. This is the recommended mechanism for
enterprise integrations where you already operate an identity system.

## When to use JWTs vs. session tokens

Use [session tokens](/docs/platform/authentication/session-tokens) if you are happy calling
`POST /v1/auth/session_token` from your backend each time a user starts a
conversation. They are simpler: no key management, instant revocation.

Use **JWTs** if any of these apply:

* You want to mint tokens locally, without a network call to Phonic.
* You need each token bound to a specific end user and conversation.
* Your security team requires customer-signed credentials for vendor APIs.

## 1. Register your signing key

In the [Phonic dashboard](https://phonic.ai/settings/jwt), register a JWKS URL
(recommended) or a static public key for your organization. Phonic fetches your
JWKS, caches it, and refreshes on `kid` mismatch. Publishing multiple keys at the
same JWKS endpoint makes rotation seamless: add the new key, wait for traffic to
shift, retire the old one.

You will also configure:

* **Issuer (`iss`)**: must match the `iss` claim on every JWT.
* **Audience (`aud`)**: we recommend `phonic.ai`.

Supported signing algorithms: `EdDSA`, `RS256`, `ES256`. We recommend `EdDSA`.

## 2. Mint a JWT

Phonic requires the following claims:

| Claim             | Required    | Description                                                                                                 |
| ----------------- | ----------- | ----------------------------------------------------------------------------------------------------------- |
| `iss`             | yes         | Must match the issuer you registered.                                                                       |
| `aud`             | yes         | Must match the audience you registered (typically `phonic.ai`).                                             |
| `sub`             | yes         | An opaque ID for your end user. Do not put PII here.                                                        |
| `conversation_id` | yes         | The conversation this token is scoped to. The token cannot be used to read or write any other conversation. |
| `exp`             | yes         | Expiration (unix seconds). We recommend ≤ 15 minutes from `iat`.                                            |
| `iat`             | yes         | Issued-at (unix seconds).                                                                                   |
| `jti`             | recommended | A unique token ID. Used for replay protection.                                                              |

```typescript
import { SignJWT, importPKCS8 } from "jose";
import { randomUUID } from "node:crypto";

const privateKey = await importPKCS8(
  process.env.PHONIC_JWT_PRIVATE_KEY!,
  "EdDSA",
);

const jwt = await new SignJWT({ conversation_id: "conv_abc123" })
  .setProtectedHeader({ alg: "EdDSA", kid: "key-2025-01" })
  .setIssuer("https://auth.your-company.com")
  .setAudience("phonic.ai")
  .setSubject("user_internal_id_456")
  .setIssuedAt()
  .setExpirationTime("10m")
  .setJti(randomUUID())
  .sign(privateKey);
```

```python
import jwt as pyjwt
import uuid
import time

with open("private_key.pem", "rb") as f:
    private_key = f.read()

now = int(time.time())

token = pyjwt.encode(
    {
        "iss": "https://auth.your-company.com",
        "aud": "phonic.ai",
        "sub": "user_internal_id_456",
        "conversation_id": "conv_abc123",
        "iat": now,
        "exp": now + 600,
        "jti": str(uuid.uuid4()),
    },
    private_key,
    algorithm="EdDSA",
    headers={"kid": "key-2025-01"},
)
```

> **Warning**
>
> Before you mint a JWT for a `(user, conversation_id)` pair, verify in your own
> backend that the user is authorized to access that conversation. Phonic only checks
> that the claim matches the request. It does not check that you should have issued
> the claim.

## 3. Use the JWT

For REST endpoints, pass the JWT in the `Authorization` header:

```http
Authorization: Bearer eyJhbGciOiJFZERTQSIsImtpZCI6...
```

For the conversation WebSocket, pass it as a query parameter (browsers cannot set
custom headers on a WebSocket handshake):

```
wss://api.phonic.ai/v1/sts/ws?jwt=eyJhbGciOiJFZERTQSIsImtpZCI6...
```

Phonic rejects any request whose `conversation_id` claim does not match the
conversation being accessed. A token minted for `conv_abc123` cannot be used to
open `conv_xyz789`, even within the same organization.

## TTL and revocation

JWTs cannot be revoked once signed; they remain valid until `exp`. This is by design:
verification stays stateless, with no Phonic-side lookup required. To "log a user
out," refuse to mint the next JWT when their client asks for one. The worst-case
exposure window after a logout equals the remaining TTL on outstanding tokens.

Pick a TTL that is:

* **Long enough** that a single conversation will not span an expiry (typically
  10–15 minutes for voice conversations).
* **Short enough** that an exposed token cannot cause prolonged damage. We
  recommend no longer than 1 hour.

If you need to invalidate a token within seconds of issuing it, use
[session tokens](/docs/platform/authentication/session-tokens) instead.

## Rate limits

JWT-authenticated requests are rate-limited per `(iss, sub, conversation_id)`. See
[Rate limits](/docs/platform/rate_limits) for current quotas.

## Common errors

| Error                          | Likely cause                                                                                             |
| ------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `401 invalid signature`        | JWT signed with a key not present in your registered JWKS. Check the `kid` header and the JWKS endpoint. |
| `401 invalid audience`         | `aud` claim does not match the audience you registered.                                                  |
| `401 token expired`            | `exp` claim is in the past. Clock skew tolerance is 30 seconds.                                          |
| `401 token not yet valid`      | `nbf` claim is in the future. Check the issuer's clock.                                                  |
| `403 conversation_id mismatch` | Token's `conversation_id` does not match the conversation being accessed.                                |
| `403 issuer not registered`    | `iss` claim does not match any registered issuer for your org.                                           |
| `409 jti replayed`             | Token's `jti` has already been used within its lifetime. Mint a new token.                               |