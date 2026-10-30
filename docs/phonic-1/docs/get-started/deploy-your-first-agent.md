> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Deploy Your First Agent

> Four ways to run agents on Phonic: the agent builder, webhooks, WebSockets, or LiveKit.

Every agent needs a system prompt, tools, and configuration. After that, you need to choose how your agent is integrated into your system or product.

| Path                            | Your code handles     | Best for                                                                                                                                          |
| ------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Agent builder](#agent-builder) | No code required      | A quick, no-code path to a working agent. Great for demos and sales, but many dev teams running in production continue to edit their agents here. |
| [Webhooks](#with-webhooks)      | HTTP endpoints        | Fire-and-forget calls: Phonic manages the session, your server supplies agent configs and consumes results via post-call webhooks.                |
| [WebSockets](#with-websockets)  | A realtime connection | More complex builds needing voice inside your own app, custom call logic, and tools kept off public internet.                                     |
| [LiveKit](#with-livekit)        | A plugin swap         | You already run voice agents on LiveKit and want to try Phonic.                                                                                   |

## Agent builder

Create an agent at [phonic.ai](https://phonic.ai). Write the system prompt, pick a voice, attach tools and a phone number, then call it and iterate. No code required. This is how most demos and evaluations happen, and it is enough for any agent served by a phone number and hosted tools. Teams also keep editing agents here after integrating, including reviewing and reverting prompt versions.

**Tradeoffs.** Everything is set per agent, so you would need to make multiple agents to vary behavior across different callers.

## With webhooks

Phonic runs the call end-to-end and your server participates over HTTP:

* Start a conversation with a single API call. Phonic orchestrates telephony, on our phone numbers or [your own](/docs/phone-numbers/using_custom_phone_numbers).
* When a call starts, Phonic calls your [agent configuration endpoint](/docs/build/with-webhooks/agent-configuration-endpoint) so you can set per-call configuration such as the caller's context or a tailored prompt.
* When a call ends, Phonic posts transcripts and analysis to your [post-call webhooks](/docs/build/with-webhooks/post-call-webhooks) for downstream processing.
* Your [webhook tools](/docs/build/tools/webhook_tools) can serve as GET or POST requests against your endpoints.

Choose this when you want your business logic in the call, but don't need to stream live audio through your product. You will still get transcripts and recordings once the call ends. See [Conversations via Webhooks](/docs/build/with-webhooks/via-webhooks).

**Tradeoffs.** This setup requires some coding, and since calls run on the phone network, you won't be able to thread the call experience through your app.

## With WebSockets

Everything the webhook path does, plus realtime control:

* Start conversations by opening a WebSocket, with access to every payload exchanged during the call.
* Bring your own audio interface: telephony, web, mobile, or anything else that produces audio.
* Answer tool calls inline on the same connection, so tools run on your infrastructure without a public endpoint.

Choose this to put voice inside an application, or when you want to keep your tools internal to your own network. See [Conversations via WebSockets](/docs/build/with-web-sockets/via-web-sockets).

**Tradeoffs.** This setup is the most complex, since you own the realtime plumbing: chunked audio streaming and holding an open connection for as long as a call lasts. Your service sits in the audio path, so its latency and uptime become part of how the call sounds. Browser clients also need [session tokens](/docs/platform/authentication/session-tokens) rather than an API key.

## With LiveKit

Already running voice agents on LiveKit? The `livekit-plugins-phonic` plugin swaps Phonic in as the realtime model without changing your LiveKit setup. See [With LiveKit](/docs/build/with-livekit).

**Tradeoffs.** LiveKit sits between your caller and Phonic, which adds a hop to the audio path. The plugin surfaces a subset of Phonic's agent configuration, and the instructions on your LiveKit agent replace the system prompt set on the Phonic agent.

The paths above run the whole call on Phonic, which keeps the audio path short and leaves turn-taking, interruption handling, and latency in one place. That is where Phonic sounds its best, so it's worth comparing a direct integration before settling on LiveKit for production.

## Switching later

The agent is the same object on every path. Its prompt, tools, and configuration carry over, so changing paths means changing your integration rather than rebuilding your agent.