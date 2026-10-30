> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# MCP Tools

> Expose tools from a connected Model Context Protocol server.

MCP tools (`mcp`) are exposed by [Model Context Protocol](https://modelcontextprotocol.io) servers you connect to Phonic. Rather than creating them one-by-one on the Tools page, you connect an MCP server and Phonic discovers the tools it exposes.

* **In the dashboard**, configure servers on the **MCP servers** page, then reference them from an agent.
* **In an agent or conversation config**, list the servers by name with `mcp_servers`, e.g. `mcp_servers: ["my-mcp-server"]`.

Like other tools, MCP tools support the standard behavior toggles (plus a per-tool timeout) — see [Tool Behavior Configuration](/docs/using-tools/tools_overview#tool-behavior-configuration).