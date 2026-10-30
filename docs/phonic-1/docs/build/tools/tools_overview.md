> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Tools Overview

> Learn about the tool types available on Phonic, how they run (sync vs async), and how to configure their behavior — both in the Phonic dashboard and through the API.

Tools let your Phonic Agent take actions beyond conversation — retrieving information, calling your own functions, injecting extra context, transferring calls, or using Model Context Protocol (MCP) servers. You can create tools two ways, and they behave identically at runtime:

* **In the dashboard** — on the [Tools page](https://phonic.co/tools), click **Create tool** and pick a type.
* **Through the API/SDK** — call [`tools.create`](https://docs.phonic.ai/api-reference/tools/create) (and [`tools.update`](https://docs.phonic.ai/api-reference/tools/update), [`tools.list`](https://docs.phonic.ai/api-reference/tools/list), [`tools.delete`](https://docs.phonic.ai/api-reference/tools/delete)).

> **Tip**
>
> Every field described in these guides maps 1:1 between the dashboard form and the API. The dashboard label is shown alongside the API field name (e.g. **Execution mode** → `execution_mode`) so you can move between the two freely.

# Tool Definition

Every custom tool shares the same core definition:

* **Name** (`name`) — a unique, snake_case identifier (lowercase letters, numbers, and underscores).
* **Description** (`description`) — tells the agent what the tool does and when to call it. Max 2000 characters.
* **Parameters** (`parameters`) — the arguments the agent supplies when calling the tool. Each parameter has a `name`, `description`, `is_required` flag, and a `type` of `string`, `integer`, `number`, `boolean`, or `array` (arrays also take an `item_type`).
* **Timeout** — how long the agent waits for a response before treating the call as failed. The exact field depends on the tool type (see each type's guide).

The name, description, and parameters make up the **tool schema** the language model sees. How the tool is executed depends on its **type**.

> **Note**
>
> Some parameter names are reserved and cannot be used: `call_info`, `conversation_id`, `from_phone_number`, `to_phone_number`, and `twilio_call_sid`. These are supplied automatically for phone calls (see [Webhook Tools → Call Context Information](/docs/using-tools/webhook_tools#call-context-information)).

# Tool Types

Phonic supports the following tool types, all creatable in the dashboard's **Create tool** menu and via the API (MCP tools are configured separately). Each type has its own guide with fields and SDK examples.

| Dashboard name           | API `type`                          | What happens when it's called                                      | Guide                                                |
| ------------------------ | ----------------------------------- | ------------------------------------------------------------------ | ---------------------------------------------------- |
| Webhook                  | `custom_webhook`                    | Phonic makes an HTTP request to your endpoint.                     | [Webhook Tools](/docs/using-tools/webhook_tools)     |
| WebSocket                | `custom_websocket`                  | Phonic sends a `tool_call` message over your WebSocket connection. | [WebSocket Tools](/docs/using-tools/websocket_tools) |
| Context                  | `custom_context`                    | Phonic injects additional context into the conversation.           | [Context Tools](/docs/using-tools/context_tools)     |
| Transfer to phone number | `built_in_transfer_to_phone_number` | Phonic transfers the call to a phone number.                       | [Transfer Tools](/docs/using-tools/transfer_tools)   |
| Transfer to agent        | `built_in_transfer_to_agent`        | Phonic transfers the conversation to another agent.                | [Transfer Tools](/docs/using-tools/transfer_tools)   |
| —                        | `mcp`                               | Phonic calls a tool exposed by a connected MCP server.             | [MCP Tools](/docs/using-tools/mcp_tools)             |
| —                        | (built-in)                          | Phonic runs a built-in capability (keypad, hang up, stay silent).  | [Built-in Tools](/docs/using-tools/built_in_tools)   |

The sections below (sync vs async, behavior configuration, attaching tools to agents) apply across all tool types.

# Sync vs Async Tools

> **Tip**
>
> For a visual walkthrough of how execution mode and the behavior flags below shape a call on a timeline, see [How tools execute](/docs/using-tools/how_tools_execute).

The **execution mode** (`execution_mode`) controls whether the agent waits for the tool before continuing:

* **Sync** — the agent waits for the tool to complete before continuing. Once the output is received, the agent uses it to generate a response. If the user speaks while the tool is executing, the tool call is interrupted. Good for tools that return information the agent needs right away.
  * Webhook: the conversation waits for your endpoint's response.
  * WebSocket: the conversation waits for the `tool_call_output` message.
* **Async** — the agent continues the conversation without waiting. Async tools are not interrupted by user speech. When the result arrives it's added to the agent's context, but doesn't immediately trigger a response. Good for background work (e.g. writing to a database) or fetching data that may be useful later.

Only `custom_webhook` and `custom_websocket` tools support choosing an execution mode. Context tools, transfer tools, and built-in tools always run in `sync` mode.

# Tool Behavior Configuration

Beyond the schema and execution mode, tools expose switches that shape *when* and *how* the agent uses them. Each maps directly to a dashboard toggle and an API field. All default to the values below.

| Dashboard toggle                 | API field                          | Default                                      | Applies to                                         | What it does                                                                                                                                                                       |
| -------------------------------- | ---------------------------------- | -------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Require speech before tool call  | `require_speech_before_tool_call`  | off                                          | all custom tools, transfers, MCP                   | Forces the agent to speak before executing the tool.                                                                                                                               |
| Wait for speech before tool call | `wait_for_speech_before_tool_call` | off                                          | webhook, websocket                                 | Makes the agent finish speaking before executing. Phonic normally executes tools as soon as possible to cut latency.                                                               |
| Forbid speech after tool call    | `forbid_speech_after_tool_call`    | off                                          | webhook, websocket, context, MCP                   | Forces the agent to not speak after executing the tool.                                                                                                                            |
| Allow tool chaining              | `allow_tool_chaining`              | on                                           | webhook, websocket, context, MCP                   | Allows the agent to execute more tools after this one.                                                                                                                             |
| Wait for response                | `wait_for_response`                | off                                          | webhook, websocket (async only)                    | Makes an async webhook or WebSocket tool wait for its response, hold off all other tools meanwhile, and inform the user of the result. Cannot be combined with tool chaining.      |
| Uninterruptible                  | `uninterruptible`                  | on for phone transfers; off for custom tools | phone transfers, webhook and websocket (sync only) | Prevents caller speech from interrupting the assistant while the tool call is running. See [phone transfer protection](/docs/using-tools/transfer_tools#transfer-to-phone-number). |

> **Note**
>
> These fields are stored per tool. When the same pre-defined tool is attached to an agent, the agent's configuration can override some of them (a per-agent tool config), so you can reuse one tool with different behavior across agents.

# Using Tools with Your Agents

Once you've created tools, attach them to an agent by including their names in the `tools` array (and MCP servers in `mcp_servers`):

```typescript
await client.agents.create({
  name: "support-agent",
  tools: [
    "keypad_input",
    "natural_conversation_ending",
    "transfer_to_support",
    "book_appointment",
  ],
  mcp_servers: ["my-mcp-server"],
  // ... other agent configuration
});
```

```python
client.agents.create(
    name="support-agent",
    tools=[
        "keypad_input",
        "natural_conversation_ending",
        "transfer_to_support",
        "book_appointment",
    ],
    mcp_servers=["my-mcp-server"],
    # ... other agent configuration
)
```

If you've included WebSocket tools in your agent, see the [WebSocket Tools guide](/docs/using-tools/websocket_tools) to learn how to handle those tool calls.