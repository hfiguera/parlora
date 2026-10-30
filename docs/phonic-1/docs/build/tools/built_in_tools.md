> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Built-in Tools

> Enable Phonic's built-in tools by adding them to an agent's tools list.

Phonic provides built-in tools that work seamlessly while handling calls on Phonic's infrastructure. The quickest way to enable one is to add its name to an agent's or conversation's `tools` array (e.g. `"tools": ["keypad_input"]`) — no tool creation needed. You can also create them as tool instances with your own name and description (see [Creating built-in tools as instances](#creating-built-in-tools-as-instances) below); both behave identically at runtime.

# Keypad Input (DTMF)

`keypad_input` lets the agent press keypad buttons including digits (0-9) and special keys (#, \*, A, B, C, D). Phonic uses out-of-band DTMF (RFC 4733) signaling with our telephony integration.

Include `keypad_input` in the agent's `tools` list. When running a conversation via WebSocket, handle the [`dtmf` message](https://docs.phonic.ai/api-reference/conversations/conversations#receive.dtmf) on your infrastructure.

# Natural Conversation Ending

`natural_conversation_ending` lets the agent hang up. Include it in the agent's `tools` list. When running via WebSocket, handle the [`assistant_ended_conversation` message](https://docs.phonic.ai/api-reference/conversations/conversations#receive.assistant_ended_conversation) on your infrastructure.

# Choose Not to Respond

`choose_not_to_respond` lets the agent stay silent for a turn instead of always replying — useful when the caller is thinking out loud, talking to someone else, or hasn't finished speaking. Include it in the agent's `tools` list. By default the agent stays silent for the rest of the turn. To have it wait and then speak a follow-up if the caller is still silent, set `respond_after_sec` to the number of seconds to wait — either in the agent's `built_in_tool_configs` under the `tool_choose_not_to_respond` key, or on a tool instance (see below).

# Creating built-in tools as instances

Instead of attaching a built-in by its bare name, you can create it as a tool with your own `name` and `description` — in the dashboard's **Create tool** menu, or via [`tools.create`](https://docs.phonic.ai/api-reference/tools/create) with `type` set to `built_in_natural_conversation_ending`, `built_in_keypad_input`, or `built_in_choose_not_to_respond`. This is useful when you want a custom-worded description for the model, and you attach the instance to an agent by its name just like any other tool.

These instances take no custom `parameters` and always run in `sync` mode (`execution_mode` is optional and defaults to `"sync"`). `built_in_natural_conversation_ending` and `built_in_keypad_input` accept an optional `speech_before_tool_call` setting — `"required"` (speak first), `"optional"` (model decides), or `"suppressed"` (stay silent before the call). It defaults to `"required"` for `built_in_natural_conversation_ending` and `"optional"` for `built_in_keypad_input`. `built_in_choose_not_to_respond` accepts an optional `respond_after_sec` — the number of seconds to wait before the agent speaks a follow-up if the caller stays silent; leave it unset (the default) to keep the agent silent for the rest of the turn.

```typescript
await client.tools.create({
  name: "hang_up",
  description: "End the call once the caller's issue is fully resolved.",
  type: "built_in_natural_conversation_ending",
  execution_mode: "sync",
  speech_before_tool_call: "suppressed",
});
```

```python
client.tools.create(
    name="hang_up",
    description="End the call once the caller's issue is fully resolved.",
    type="built_in_natural_conversation_ending",
    execution_mode="sync",
    speech_before_tool_call="suppressed",
)
```