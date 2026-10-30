> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Webhooks

> Learn how to use Phonic webhooks

Webhooks allows you to receive real-time notifications to your application when specific events occur.
Instead of polling our API to check for updates, Phonic will send event data directly to your server as events happen, making your integration more efficient and responsive.

To receive webhooks, configure them first on the [Webhooks page](https://phonic.co/webhooks).

## Available Webhooks

* [conversation.ended](/webhooks/conversation-ended) - Triggered when conversation ends
* [conversation.analysis](/webhooks/conversation-analysis) - Triggered when conversation analysis completes
* [conversation.transferred](/webhooks/conversation-transferred) - Triggered when a call is transferred to a phone number