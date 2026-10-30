> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Python SDK

> Build voice agents with the Phonic Python SDK.

## Install

```bash
pip install phonic
```

## Initialize the client

```python
import os
from phonic import Phonic

client = Phonic(
  api_key=os.getenv("PHONIC_API_KEY"),
)
```

## Create an agent

```python
client.agents.create(
  name="my-first-agent",
  phone_number="assign-automatically",
)
```

## Make an outbound call

```python
client.conversations.outbound_call(
  to_phone_number="YOUR_PHONE_NUMBER", # e.g. +19189391262
  config={
    "agent": "my-first-agent",
    "welcome_message": "Hello, how can I help you?",
  },
)
```

> **Tip**
>
> See [Via Webhooks](/docs/build/with-webhooks/via-webhooks) for the full walkthrough, including inbound calls, or the [API reference](/api-reference) for the complete SDK surface. An `AsyncPhonic` client is also available for async code.