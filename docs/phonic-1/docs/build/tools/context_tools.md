> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Context Tools

> Inject additional context into the conversation on demand.

Context tools (`custom_context`) don't call an external endpoint. Instead, when the agent invokes the tool, Phonic injects a block of **context** (`context`) into the conversation. This is useful for surfacing instructions or reference material on demand — for example, a detailed script for handling a specific request that would clutter the main system prompt if always present.

See [Tool Definition](/docs/using-tools/tools_overview#tool-definition) for the shared fields and [Tool Behavior Configuration](/docs/using-tools/tools_overview#tool-behavior-configuration) for the behavior toggles.

Because they only inject text, Context tools:

* Cannot have parameters.
* Always run in `sync` execution mode (they cannot be `async`).
* Provide a **Context** field (`context`, up to 64,000 characters) instead of an endpoint.

In the dashboard, choose **Context** in the **Create tool** menu ("We'll inject additional context into the conversation.") and fill in the **Context** textarea.

# Creating a Context Tool

```typescript
await client.tools.create({
  name: "urgent_request",
  description:
    "Instructions for assisting with an urgent customer request.",
  type: "custom_context",
  execution_mode: "sync",
  context:
    "When the caller reports an outage, first confirm the account ID, then ...",
});
```

```python
client.tools.create(
    name="urgent_request",
    description="Instructions for assisting with an urgent customer request.",
    type="custom_context",
    execution_mode="sync",
    context="When the caller reports an outage, first confirm the account ID, then ...",
)
```