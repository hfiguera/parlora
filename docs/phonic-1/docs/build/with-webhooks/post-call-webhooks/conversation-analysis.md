> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# conversation.analysis

The conversation analysis webhook is triggered when conversation analysis completes.

## Webhook payload

Here is an example of the POST request JSON payload:

```json
{
  "event_type": "conversation.analysis",
  "data": {
    "conversation": {
      "id": "conv_550e8400-e29b-41d4-a716-446655440000",
      "latencies_ms": [3179, 935, 595],
      "interruptions_count": 1
    },
    "call_info": {
      "from_phone_number": "+17124583766",
      "to_phone_number": "+19189397081"
    }
  },
  "created_at": "2025-07-14T11:36:33.767Z"
}
```

## Payload fields

**`event_type`** `string` — required

Always `"conversation.analysis"`

---

**`created_at`** `string` — required

ISO 8601 timestamp of when the event was created

---

**`data.conversation.id`** `string` — required

The ID of the conversation analysis

---

**`data.conversation.latencies_ms`** `integer[]` — required

Array of response latencies in milliseconds for each assistant turn

---

**`data.conversation.interruptions_count`** `integer` — required

Number of times the user interrupted the assistant

---

**`data.call_info`** `CallInfo | null`

Phone call metadata (present for telephony conversations, `null` for web). Contains `from_phone_number`, `to_phone_number`, and optionally `twilio_call_sid`.

---

## Example usage

Here's an example of how to handle the webhook:

```typescript
import { Hono } from "hono";
import { Webhook } from "svix";

const app = new Hono();

app.post("/webhooks/phonic", async (c) => {
  if (!process.env.PHONIC_WEBHOOK_SECRET) {
    return c.text("Bad Request", 400);
  }

  const wh = new Webhook(process.env.PHONIC_WEBHOOK_SECRET);
  const rawBody = await c.req.text();

  try {
    const payload = wh.verify(rawBody, {
      "svix-id": c.req.header("svix-id") ?? "",
      "svix-timestamp": c.req.header("svix-timestamp") ?? "",
      "svix-signature": c.req.header("svix-signature") ?? "",
    }) as ConversationAnalysisWebhookPayload;

    const { latencies_ms, interruptions_count } = payload.data.conversation;
    console.log(`Latencies: ${latencies_ms}, Interruptions: ${interruptions_count}`);

    return c.text("OK", 200);
  } catch (error) {
    console.error("Failed to verify webhook:", error);

    return c.text("Bad Request", 400);
  }
});

export default app;
```

```python
import os

from fastapi import FastAPI, Request
from fastapi.responses import PlainTextResponse
from svix.webhooks import Webhook, WebhookVerificationError

app = FastAPI()

@app.post("/webhooks/phonic")
async def handle_webhook(request: Request) -> PlainTextResponse:
    secret = os.environ.get("PHONIC_WEBHOOK_SECRET")
    if not secret:
        return PlainTextResponse("Bad Request", status_code=400)

    raw_body = await request.body()
    headers = {
        "svix-id": request.headers.get("svix-id", ""),
        "svix-timestamp": request.headers.get("svix-timestamp", ""),
        "svix-signature": request.headers.get("svix-signature", ""),
    }

    try:
        wh = Webhook(secret)
        payload = wh.verify(raw_body, headers)

        conversation = payload["data"]["conversation"]
        latencies = conversation["latencies_ms"]
        interruptions = conversation["interruptions_count"]
        print(f"Latencies: {latencies}, Interruptions: {interruptions}")

        return PlainTextResponse("OK", status_code=200)
    except WebhookVerificationError:
        return PlainTextResponse("Bad Request", status_code=400)
```