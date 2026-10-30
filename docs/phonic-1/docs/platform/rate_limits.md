> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

Rate-limited requests return HTTP status code `429`.

Rate limits are per organization:

| Endpoint group                               | Limit                                                       |
| -------------------------------------------- | ----------------------------------------------------------- |
| `/conversations/sip/outbound_call` `/sts/ws` | 500 requests per second total, shared across both endpoints |
| `/conversations/outbound_call`               | 5 requests per second                                       |
| All other authenticated endpoints            | 500 requests per second, shared across all endpoints        |