> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Webhook Tools

> Call your own HTTP endpoint when the agent invokes a tool.

When a Webhook tool (`custom_webhook`) is called, Phonic makes an HTTP request to the endpoint you configured. Webhook tools work whether you run a conversation [via Webhook](https://docs.phonic.ai/docs/conversations/via-webhooks) or [via WebSocket](https://docs.phonic.ai/docs/conversations/via-web-sockets).

See [Tool Definition](/docs/using-tools/tools_overview#tool-definition) for the shared `name`, `description`, and `parameters` fields, and [Tool Behavior Configuration](/docs/using-tools/tools_overview#tool-behavior-configuration) for the behavior toggles.

# Endpoint

In the dashboard, under **Endpoint** you set:

* **Method** (`endpoint_method`) — `GET` or `POST`.
* **URL** (`endpoint_url`) — must be a publicly routable URL.
* **Headers** (`endpoint_headers`) — optional, e.g. an `Authorization` header. Header values can contain custom [template variables](/docs/build/agents/template-variables#webhook-tool-headers), such as `Bearer {{customer_api_token}}`, filled in per conversation.
* **Timeout** (`endpoint_timeout_ms`) — default 5000 ms, between 1000 and 180000 ms.

All parameters of a `GET` Webhook tool go in the query string. For `POST` Webhook tools, each parameter has a **location** (`request_body` or `query_string`).

# Call Context Information

When a Webhook tool is used with an Agent making calls on Phonic's infrastructure, call context (`call_info`) is automatically included in the request:

* `conversation_id`: The unique identifier for the current conversation
* `from_phone_number`: The caller's phone number (when available)
* `to_phone_number`: The destination phone number (when available)

## GET Webhook Request Format

For `GET` Webhook tools, call context and parameters are included as query string parameters:

```
GET /your-endpoint?city=Seattle&temperature_unit=celsius&conversation_id=conv_abc123&from_phone_number=%2B15551234567&to_phone_number=%2B15557654321
```

* Tool parameters: query string parameters (e.g., `city`, `temperature_unit`)
* Call context: individual query string parameters (`conversation_id`, `from_phone_number`, `to_phone_number`)

## POST Webhook Request Format

For `POST` Webhook tools, the request body includes a `call_info` object along with your tool parameters:

```json
{
    "call_info": {
        "conversation_id": "conv_abc123",
        "from_phone_number": "+15551234567",
        "to_phone_number": "+15557654321"
    },
    "city": "Seattle",
    "temperature_unit": "celsius"
}
```

* Tool parameters: at the root level of the JSON body (e.g., `city`, `temperature_unit`)
* Call context: in a nested `call_info` object

## TypeScript Interface Examples

**For GET Webhooks:**

```typescript
// Query parameters your endpoint will receive
interface GetWeatherWebhookParams {
  // Your tool parameters
  city: string;
  temperature_unit?: string;

  // Call context (automatically added by Phonic)
  conversation_id: string;
  from_phone_number?: string;
  to_phone_number?: string;
}
```

**For POST Webhooks:**

```typescript
// Request body your endpoint will receive
interface PostWeatherWebhookBody {
  // Call context (automatically added by Phonic)
  call_info: {
    conversation_id: string;
    from_phone_number?: string;
    to_phone_number?: string;
  };

  // Your tool parameters
  city: string;
  temperature_unit?: string;
}
```

> **Note**
>
> The Webhook tool response body is added to the agent's context, but is truncated if its JSON serialized representation exceeds 16,000 characters.

# Creating a Webhook Tool

```typescript
import { config } from "dotenv";
import { PhonicClient } from "phonic";

config({ path: ".env.local" });

const apiKey = process.env.PHONIC_API_KEY;
const client = new PhonicClient({ apiKey });

async function createTool() {
  await client.tools.create({
    name: "add_destination",
    description:
      "Add a destination to the list when the user indicates they will visit it.",
    type: "custom_webhook",
    execution_mode: "sync",
    endpoint_method: "POST",
    endpoint_url: `https://${NGROK_URL.replace("https://", "")}/webhooks/add-destination`,
    endpoint_timeout_ms: 7000,
    parameters: [
      {
        name: "destination_name",
        description: "The name of the destination",
        is_required: true,
        type: "string",
      },
    ],
  });
}

createTool()
```

```python
import os
from dotenv import load_dotenv

load_dotenv(".env.local")

client = Phonic(api_key=os.getenv("PHONIC_API_KEY"))

client.tools.create(
    name="add_destination",
    description="Add a destination to the list when the user indicates they will visit it.",
    type="custom_webhook",
    execution_mode="sync",
    endpoint_method="POST",
    endpoint_url=f"https://{NGROK_URL}/webhooks/add-destination",
    endpoint_timeout_ms=7000,
    parameters=[
        {
            "name": "destination_name",
            "description": "The name of the destination",
            "is_required": True,
            "type": "string",
        }
    ],
)
```