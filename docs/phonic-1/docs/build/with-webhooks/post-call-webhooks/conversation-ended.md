> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# conversation.ended

The conversation ended webhook is triggered when conversation ends.

## Webhook payload

Here is an example of the POST request JSON payload:

```json
{
  "event_type": "conversation.ended",
  "data": {
    "conversation": {
      "id": "conv_894dcb66-c3dd-4160-8606-30387e8ab9b5",
      "agent": {
        "id": "agent_123",
        "name": "Customer Support",
        "is_deleted": false
      },
      "workspace": "phonic",
      "project": {
        "id": "proj_8e5bdac5-868d-46fa-b397-439e777f7bfd",
        "name": "main"
      },
      "external_id": null,
      "model": "phonic-1",
      "welcome_message": "Hey, how can I help?",
      "template_variables": {},
      "input_format": "pcm_44100",
      "output_format": "pcm_44100",
      "live_transcript": "Hey, how can I help?",
      "post_call_transcript": null,
      "duration_ms": 46537,
      "background_noise_level": 0.1,
      "background_noise": null,
      "boosted_keywords": null,
      "pronunciation_dictionary": [{"word": "Phuket", "pronunciation": "Poo-ket"}],
      "min_words_to_interrupt": 1,
      "default_language": "en",
      "additional_languages": [],
      "multilingual_mode": "request",
      "push_to_talk": false,
      "no_input_poke_sec": null,
      "no_input_poke_text": null,
      "no_input_end_conversation_sec": null,
      "audio_url": "...",
      "started_at": "2025-07-14T11:35:40.617Z",
      "ended_at": "2025-07-14T11:36:27.154Z",
      "ended_by": "user",
      "task_results": {},
      "items": [
        {
          "item_idx": 0,
          "role": "assistant",
          "live_transcript": "Hey, how can I help?",
          "voice_id": "grant",
          "system_prompt": "Help the user to book a dentist appointment.",
          "audio_speed": 1,
          "duration_ms": 26.71,
          "started_at": "2025-07-14T11:35:41.717Z",
          "tool_calls": []
        }
      ]
    },
    "call_info": {
      "from_phone_number": "+17124583766",
      "to_phone_number": "+19189397081"
    }
  },
  "created_at": "2025-07-14T11:36:33.768Z"
}
```

## Payload fields

**`event_type`** `string` — required

Always `"conversation.ended"`

---

**`created_at`** `string` — required

ISO 8601 timestamp of when the event was created

---

**`data.conversation`** `Conversation` — required

The full conversation object. See the [Get Conversation](/api-reference/conversations/get) endpoint for all fields.

---

**`data.call_info`** `CallInfo | null`

Phone call metadata (present for telephony conversations, `null` for web). Contains `from_phone_number`, `to_phone_number`, and optionally `twilio_call_sid`.

---

## Example usage

Here's an example of how to handle the webhook:

```typescript
import { Hono } from "hono";
import { Webhook } from "svix";
import type { Phonic } from "phonic";

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
    }) as Phonic.ConversationEndedWebhookPayload;

    const conversation = payload.data.conversation;
    console.log(`Conversation ${conversation.id} ended`);

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
        print(f"Conversation {conversation['id']} ended")

        return PlainTextResponse("OK", status_code=200)
    except WebhookVerificationError:
        return PlainTextResponse("Bad Request", status_code=400)
```