> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

The simplest way to run a conversation with Phonic is via webhooks — start a conversation
with a single function call, and let Phonic orchestrate telephony for you.

> **Note**
>
> Complete the [Introduction](/docs/get-started/overview) page first to get your account and API key.

This guide walks through your first webhook conversation, then covers two more advanced
features. The example code is available
[here](https://github.com/Phonic-Co/phonic-examples/tree/main/01-quick-start) and
[here](https://github.com/Phonic-Co/phonic-examples/tree/main/02-conversation-webhook).

## 1. Install the SDK

```typescript
npm install phonic
```

```python
pip install phonic
```

See [TypeScript SDK](/docs/get-started/installation/typescript_sdk) or [Python SDK](/docs/get-started/installation/python_sdk) for more on the client.

## 2. Initialize the client

```typescript
import { PhonicClient } from "phonic";
import { config } from "dotenv";

config({ path: ".env.local" });

const client = new PhonicClient({
  apiKey: process.env.PHONIC_API_KEY,
});
```

```python
import os
from dotenv import load_dotenv
from phonic import Phonic

load_dotenv(".env.local")

client = Phonic(
  api_key=os.getenv("PHONIC_API_KEY"),
)
```

> **Tip**
>
> Install `dotenv` (`npm install dotenv` / `pip install python-dotenv`) to load the API key from `.env.local`.

## 3. Create an agent

Let's create an agent and assign it a random phone number.

```typescript
await client.agents.create({
  name: "my-first-agent",
  phone_number: "assign-automatically",
});
```

```python
client.agents.create(
  name="my-first-agent",
  phone_number="assign-automatically",
)
```

You should see now `my-first-agent` on the [Agents page](https://phonic.co/agents).

## 4. Make an outbound call

Let's make the agent call you. Specify your phone number, the agent name, and a welcome message:

```typescript
await client.conversations.outboundCall({
  to_phone_number: "YOUR_PHONE_NUMBER", // e.g. +19189391262
  config: {
    agent: "my-first-agent",
    welcome_message: "Hello, how can I help you?",
  }
});
```

```python
client.conversations.outbound_call(
  to_phone_number="YOUR_PHONE_NUMBER", # e.g. +19189391262
  config={
    "agent": "my-first-agent",
    "welcome_message": "Hello, how can I help you?",
  },
)
```

Now, pick up the phone and chat with your agent!

## 5. Make an inbound call

Grab the agent's phone number on the [Agents page](https://phonic.co/agents), and give it a call!

> **Tip**
>
> See [here](https://github.com/Phonic-Co/phonic-examples/tree/main/01-quick-start) for a complete code example.

## Agent configuration endpoint

Typically, when you create an agent with Phonic you specify default values for its behavior, such as
its welcome message and system prompt.
With the agent configuration endpoint, you have the option at the start of every conversation
to update your agent with conversation-specific information.

This is primarily useful for inbound calls; for example, your endpoint can look up the inbound caller
in your CRM and populate your welcome message with the caller information.

At the start of every conversation, Phonic sends a **POST** request to your endpoint, and your
endpoint returns configuration overrides for that conversation. See the
[Agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint) reference for the full
request and response payload shapes.

Implementing your configuration endpoint is easy:

```typescript
import { Hono } from "hono";

const app = new Hono();

app.post("/webhooks/agent-config", async (c) => {
  const body = (await c.req.json()) as Phonic.PhonicConfigurationEndpointRequestPayload;
  const fromPhoneNumber = body.from_phone_number;
  const fromCustomerName = lookUpCustomerName(fromPhoneNumber);  // look up customer in your CRM
  const response: Phonic.PhonicConfigurationEndpointResponsePayload = {
    welcome_message: `Hey ${fromCustomerName}, how can I help you today?`,
  };
  return c.json(response);
});
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

## Post-call analysis endpoint

Upon the completion of each conversation, you can report conversation information, such as the full
transcript, system prompt, and start/end timestamps. Implementing this is also easy:

```typescript
import { Hono } from "hono";

const app = new Hono();

app.post("/webhooks/post-call", async (c) => {
    const body = await c.req.json();
    save_conversation(body);  // save conversation information to your database
    return c.json({ message: "OK" });
});
```

```python
from fastapi import FastAPI, Request, Response

app = FastAPI()

@app.post("/webhooks/post-call")
async def post_call(request: Request) -> Response:
    raw_body = await request.body()
    body = json.loads(raw_body)
    save_conversation(body)  # save conversation information to your database
    return Response(content="OK", status_code=200)
```

> **Tip**
>
> See [here](https://github.com/Phonic-Co/phonic-examples/tree/main/02-conversation-webhook) for a complete code example.