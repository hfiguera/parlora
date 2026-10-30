> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# WebSocket Tools

> Run tools on your own server during a WebSocket conversation.

This guide shows how to extend a [basic WebSocket conversation](/docs/conversations/via-web-sockets) to work with WebSocket tools.

While this guide runs through creating and using a `sync` WebSocket tool, the core workflow remains the same with `async` WebSocket tools.

> **Tip**
>
> Full working examples in both Node and Python are available in the [Phonic examples repository](https://github.com/Phonic-Co/phonic-examples/tree/main/04-conversation-websocket-tools).

# Prerequisites

Before adding tools to your WebSocket conversation, you should have:

* A working WebSocket server that connects to Phonic (see [Via WebSockets guide](/docs/conversations/via-web-sockets))

# Tool Call Messages

When the agent makes a tool call, Phonic sends this message over the WebSocket:

```ts
{
  "type": "tool_call",
  "tool_call_id": "string",
  "tool_name": "string",
  "parameters": {
    // Map from parameter names to values
  }
}
```

Respond with a `tool_call_output` message:

```ts
{
  type: "tool_call_output";
  tool_call_id: string; // The ID from the tool_call message
  output: unknown; // The result, can be any JSON-serializable object
}
```

WebSocket tools expose an **Output timeout** (`tool_call_output_timeout_ms`) — the maximum time to wait for the `tool_call_output` message. Default 5000 ms, between 1000 and 180000 ms.

> **Note**
>
> The WebSocket tool call output may be any JSON-serializable value, but is truncated if its JSON serialized representation exceeds 16,000 characters.

# Adding Tool Support

To handle tool calls in your existing WebSocket server, you need to:

1. Listen for `tool_call` messages from Phonic
2. Process the tool call with your business logic
3. Send back a `tool_call_output` message with the result

## Step 1: Choose How to Provide Tools

You can provide WebSocket tools in two ways:

* **Pre-defined WebSocket tools**: create the tool once with the Tools API or Phonic UI, then reference it by name from an agent or conversation config. Use pre-defined WebSocket tools to avoid having to define the same tool across agents or conversations.
* **Inline WebSocket tools**: define the tool inline in the WebSocket `config` message. Inline WebSocket tools are not persisted to your workspace. Use inline WebSocket tools when the parameters for the tool may change between conversations.

Inline tools are defined when you make the tool available (see [Step 2](#step-2-make-the-tool-available)). For a pre-defined tool, create it first with the Tools API or in the dashboard:

```typescript
import { PhonicClient } from "phonic";

const phonic = new PhonicClient({ apiKey: process.env.PHONIC_API_KEY });

await phonic.tools.create({
  name: "get_temperature",
  description: "Get the current temperature for a specific city",
  type: "custom_websocket",
  execution_mode: "sync",
  parameters: [
    {
      type: "string",
      name: "city",
      description: "The city to get the temperature for",
      is_required: true,
    },
  ],
});
```

```python
from phonic import Phonic

client = Phonic(api_key=os.getenv("PHONIC_API_KEY"))

client.tools.create(
    name="get_temperature",
    description="Get the current temperature for a specific city",
    type="custom_websocket",
    execution_mode="sync",
    parameters=[
        {
            "type": "string",
            "name": "city",
            "description": "The city to get the temperature for",
            "is_required": True,
        },
    ],
)
```

## Step 2: Make the Tool Available

### Pre-defined Tools

Add pre-defined tools to your agent's configuration by name:

```typescript
await phonic.agents.create({
  name: "weather-assistant",
  tools: ["get_temperature"],  // Add your tool here
  // ... other agent configuration
});
```

```python
client.agents.create(
    name="weather-assistant",
    tools=["get_temperature"],  # Add your tool here
    # ... other agent configuration
)
```

### Inline WebSocket Tools

For inline WebSocket tools, pass the tool definition inline when you start the WebSocket conversation. The `tool_schema` follows OpenAI's function tool shape.

Inline tools currently support `type: "custom_websocket"` only.

```typescript
await phonicSocket.sendConfig({
  type: "config",
  agent: "weather-assistant",
  tools: [
    {
      type: "custom_websocket",
      tool_schema: {
        type: "function",
        function: {
          name: "get_temperature",
          description: "Get the current temperature for a specific city",
          parameters: {
            type: "object",
            properties: {
              city: {
                type: "string",
                description: "The city to get the temperature for",
              },
            },
            required: ["city"],
            additionalProperties: false,
          },
          strict: true,
        },
      },
      execution_mode: "sync",
      tool_call_output_timeout_ms: 5000,
    },
  ],
});
```

```python
await socket.send_config(
    ConfigPayload(
        agent="weather-assistant",
        tools=[
            {
                "type": "custom_websocket",
                "tool_schema": {
                    "type": "function",
                    "function": {
                        "name": "get_temperature",
                        "description": "Get the current temperature for a specific city",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "city": {
                                    "type": "string",
                                    "description": "The city to get the temperature for",
                                },
                            },
                            "required": ["city"],
                            "additionalProperties": False,
                        },
                        "strict": True,
                    },
                },
                "execution_mode": "sync",
                "tool_call_output_timeout_ms": 5000,
            }
        ],
    )
)
```

## Step 3: Handle Tool Calls in Your WebSocket Server

Modify your existing WebSocket message handler to process `tool_call` messages:

```typescript
// Add to your existing phonicSocket message handler
phonicSocket.on("message", async (message) => {
  // Your existing handlers for audio_chunk, etc...
  
  // Add: Handle tool calls
  if (message.type === "tool_call") {
    switch (message.tool_name) {
      case "get_temperature": {
        const { city } = message.parameters;
        
        // Your implementation
        const temperature = await getTemperature(city);
        
        // Send result back to Phonic
        await phonicSocket.sendToolCallOutput({
          type: "tool_call_output",
          tool_call_id: message.tool_call_id,
          output: {
            city: city,
            temperature: "75°F"
          },
        });
        break;
      }
    }
  }
});
```

```python
# Add to your existing message handler
async def receive_from_phonic(message: ConversationsSocketClientResponse):
    # Your existing handlers for audio_chunk, etc...
    
    # Add: Handle tool calls
    if message.type == "tool_call":
        if message.tool_name == "get_temperature":
            city = message.parameters["city"]
            
            # Your implementation
            temperature = await get_temperature(city)
            
            # Send result back to Phonic
            await socket.send_tool_call_output(
                ToolCallOutputPayload(
                    tool_call_id=message.tool_call_id,
                    output={
                        "city": city,
                        "temperature": "75°F"
                    },
                )
            )
```

> **Tip**
>
> See the complete examples in our [examples repository](https://github.com/Phonic-Co/phonic-examples/tree/main/04-conversation-websocket-tools).