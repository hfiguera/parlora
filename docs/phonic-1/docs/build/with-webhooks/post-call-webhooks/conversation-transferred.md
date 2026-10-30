> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# conversation.transferred

The conversation transferred webhook is triggered when a call is successfully transferred to a phone number.

## Webhook payload

Here is an example of the POST request JSON payload:

```json
{
  "event_type": "conversation.transferred",
  "data": {
    "conversation": {
      "id": "conv_894dcb66-c3dd-4160-8606-30387e8ab9b5",
      "items": [
        {
          "role": "assistant",
          "text": "Let me transfer you now."
        },
        {
          "role": "user",
          "text": "Thanks!"
        }
      ]
    },
    "transferred_to": "+15551234567",
    "call_info": {
      "from_phone_number": "+6461234567",
      "to_phone_number": "+14151234567"
    }
  },
  "created_at": "2025-07-14T11:36:33.767Z"
}
```

## Payload fields

**`event_type`** `string` — required

Always `"conversation.transferred"`

---

**`created_at`** `string` — required

ISO 8601 timestamp of when the event was created

---

**`data.conversation.id`** `string` — required

Unique conversation identifier

---

**`data.conversation.items`** `ConversationItem[]` — required

Array of conversation turns. See the [Get Conversation](/api-reference/conversations/get) endpoint for the full `ConversationItem` type.

---

**`data.transferred_to`** `string` — required

The phone number the call was transferred to, in E.164 format

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
    }) as ConversationTransferredWebhookPayload;

    const { conversation, transferred_to } = payload.data;
    console.log(`Conversation ${conversation.id} transferred to ${transferred_to}`);

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
        transferred_to = payload["data"]["transferred_to"]
        print(f"Conversation {conversation['id']} transferred to {transferred_to}")

        return PlainTextResponse("OK", status_code=200)
    except WebhookVerificationError:
        return PlainTextResponse("Bad Request", status_code=400)
```