> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Agent Configuration Endpoint

The agent configuration endpoint lets you dynamically configure a conversation at the moment it
starts. When an agent has a `configuration_endpoint` set, Phonic sends a **POST** request to your
URL at the start of every conversation, and your endpoint returns configuration overrides for that
specific conversation.

This is primarily useful for inbound calls — for example, your endpoint can look up the inbound
caller in your CRM and populate the welcome message with the caller's information.

## Setup

Add a `configuration_endpoint` to your agent (via the dashboard or the
[Update Agent](/api-reference/agents/update) endpoint):

```json
{
  "configuration_endpoint": {
    "url": "https://your-server.com/webhooks/agent-config",
    "headers": { "Authorization": "Bearer your-secret" },
    "timeout_ms": 3000
  }
}
```

* `url` must be a publicly routable HTTPS URL without embedded credentials.
* `timeout_ms` must be between `1000` and `20000`. Defaults to `3000`.

You can also set a `configuration_endpoint` on an individual custom phone number (see
[Add Custom Phone Number](/api-reference/agents/add-custom-phone-number) and
[Update Phone Number](/api-reference/agents/update-phone-number)). For inbound calls to that number,
the phone number's endpoint is used instead of the agent's.

## Request payload

Phonic sends a JSON body with the following fields:

```json
{
  "project": { "name": "main" },
  "agent": {
    "name": "support-agent",
    "welcome_message": "Hi, how can I help you today?",
    "voice_id": "sabrina",
    "additional_voice_ids": [],
    "system_prompt": "You are a helpful support assistant.",
    "tools": ["check_order_status", "create_ticket"],
    "tasks": [{ "name": "verify_identity", "description": "Confirm the caller's date of birth." }],
    "boosted_keywords": ["order ID", "tracking number"]
  },
  "template_variables": { "system_conversation_timezone": "America/Los_Angeles" },
  "conversation_id": "conv_abc123",
  "from_phone_number": "+15551234567",
  "to_phone_number": "+15559876543"
}
```

**`project`** `object` — required

The project the conversation belongs to. Contains `name` (string).

---

**`agent`** `object | null` — required

A subset of the [Agent](/api-reference/agents/get) for this conversation. Contains `name`,
`welcome_message`, `voice_id`, `additional_voice_ids`, `system_prompt`, `tools` (tool names as
strings), `tasks` (objects with `name` and `description`), and `boosted_keywords`. `null` when the
conversation has no agent (for example, a WebSocket conversation started with a
`configuration_endpoint` in its config instead of an agent).

---

**`template_variables`** `object` — required

Template variables already provided for the conversation (for example, in the WebSocket config or
the outbound call request). Always includes `system_conversation_timezone`.

---

**`conversation_id`** `string` — required

Unique ID for the conversation.

---

**`from_phone_number`** `string`

Caller's phone number in E.164 format. Present for inbound and outbound phone calls.

---

**`to_phone_number`** `string`

Phone number that was called in E.164 format. Present for inbound and outbound phone calls.

---

**`twilio_call_sid`** `string`

Present when using SIP trunking with a custom phone number — the Twilio Call SID in your
Twilio environment.

---

## Response payload

Your endpoint returns a JSON object. **Every field is optional** — any field you return
overrides the agent's configured value for that conversation, and any field you omit falls back to
the agent's default. Return `{}` to make no changes. Fields set directly on the conversation (in the
WebSocket config or the outbound call request) take precedence over your endpoint's response.

```json
{
  "welcome_message": "Hey David, how can I help you today?",
  "system_prompt": "You are helping David, a premium customer.",
  "template_variables": { "customer_name": "David" },
  "voice_id": "sabrina",
  "default_language": "en",
  "metadata": { "crm_id": "cus_123" }
}
```

The response accepts the same configuration fields as the [Create Agent](/api-reference/agents/create)
endpoint — see it for descriptions of each field. The most commonly used fields are:

**`welcome_message`** `string | null`

Message to play when the conversation starts. Can contain template variables. Ignored when
`generate_welcome_message` is `true`.

---

**`system_prompt`** `string`

Instructions for the conversation. Can contain template variables.

---

**`template_variables`** `object`

Key-value pairs of template variables used in the welcome message and system prompt. See
[template variables](/docs/build/agents/template-variables).

---

**`voice_id`** `string`

The voice ID to use for the agent. See [voices](/docs/build/agents/voices).

---

**`tools`** `string[]`

Built-in or custom tool names to make available to the assistant.

---

**`default_language`** `string`

ISO 639-1 language code that sets the agent's default language.

---

**`additional_languages`** `string[]`

Additional ISO 639-1 language codes the agent should recognize and speak.

---

**`metadata`** `object`

Arbitrary key-value metadata to associate with the conversation. Available to the system prompt as
the `{{metadata}}` template variable. If the system prompt uses `{{metadata}}`, the response must
include `metadata`. The welcome message can't use `{{metadata}}`. See
[the `metadata` variable](/docs/build/agents/template-variables#the-metadata-variable).

---

> **Note**
>
> The response is validated strictly: unknown fields are rejected. `outbound_number_pool` and
> `configuration_endpoint` are **not** accepted, since they don't apply once a conversation is
> starting. `agent` and `project` are ignored.

## Errors

If the endpoint call fails, the conversation ends instead of falling back to the agent's
configuration. The WebSocket is closed with one of these codes:

| Code   | Reason                                                                                                           |
| ------ | ---------------------------------------------------------------------------------------------------------------- |
| `4305` | The endpoint didn't respond within `timeout_ms`.                                                                 |
| `4306` | The endpoint returned a non-2xx status (redirects are not followed), couldn't be reached, or didn't return JSON. |
| `4307` | The response failed validation (for example, an unknown field or an invalid value).                              |

A `voice_id` or `additional_voice_ids` your organization can't access also ends the conversation.

## Example usage

Here's an example of how to implement the endpoint:

```typescript
import { Hono } from "hono";
import type { Phonic } from "phonic";

const app = new Hono();

app.post("/webhooks/agent-config", async (c) => {
  const body = (await c.req.json()) as Phonic.PhonicConfigurationEndpointRequestPayload;
  const fromPhoneNumber = body.from_phone_number;
  const fromCustomerName = lookUpCustomerName(fromPhoneNumber); // look up customer in your CRM
  const response: Phonic.PhonicConfigurationEndpointResponsePayload = {
    welcome_message: `Hey ${fromCustomerName}, how can I help you today?`,
  };
  return c.json(response);
});

export default app;
```

```python
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()

@app.post("/webhooks/agent-config")
async def agent_config(request: Request) -> JSONResponse:
    body = await request.json()
    from_phone_number = body["from_phone_number"]
    from_customer_name = look_up_customer_name(from_phone_number)  # look up customer in your CRM
    response = {
        "welcome_message": f"Hey {from_customer_name}, how can I help you today?",
    }
    return JSONResponse(content=response)
```