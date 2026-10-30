# Phonic-1 documentation snapshot

Official Phonic documentation selected for evaluating a provider adapter in the Parlora library. Downloaded pages and API specifications are preserved unmodified, using the source website’s path structure.

The snapshot contains 43 Markdown pages, the official `llms.txt` discovery index, and OpenAPI and AsyncAPI JSON specifications. Retrieval time, source URLs, byte counts, and SHA-256 hashes are recorded in [manifest.json](manifest.json).

## Start here

- [Speech-to-speech WebSocket API and message schemas](api-reference/conversations/conversations.md)
- [WebSocket integration guide](docs/build/with-web-sockets/via-web-sockets.md)
- [Client-side WebSocket tools](docs/build/tools/websocket_tools.md)
- [Tool execution, async results, and interruption behavior](docs/build/tools/how_tools_execute.md)
- [Tool types and behavior flags](docs/build/tools/tools_overview.md)
- [Agent configuration schema](api-reference/agents/create.md)
- [Authentication](docs/platform/authentication/overview.md)
- [Rate limits](docs/platform/rate_limits.md)
- [Data retention](docs/platform/retention.md)
- [Evaluation guide](docs/build/agents/evals_guide.md)

## API specifications

- [AsyncAPI JSON](asyncapi.json): speech-to-speech WebSocket channel and message definitions.
- [OpenAPI JSON](openapi.json): HTTP endpoints and configuration schemas.
- [Official documentation index](llms.txt): discovery links, including pages outside this selected snapshot.

## Retained pages

### API references

- [Agents — Create](api-reference/agents/create.md) · [source](https://docs.phonic.ai/api-reference/agents/create.md)
- [Auth — Create Conversation Token](api-reference/auth/create-conversation-token.md) · [source](https://docs.phonic.ai/api-reference/auth/create-conversation-token.md)
- [Auth — Create Session Token](api-reference/auth/create-session-token.md) · [source](https://docs.phonic.ai/api-reference/auth/create-session-token.md)
- [Conversation Items — Replay](api-reference/conversation-items/replay.md) · [source](https://docs.phonic.ai/api-reference/conversation-items/replay.md)
- [Conversations — Cancel](api-reference/conversations/cancel.md) · [source](https://docs.phonic.ai/api-reference/conversations/cancel.md)
- [Conversations — conversations](api-reference/conversations/conversations.md) · [source](https://docs.phonic.ai/api-reference/conversations/conversations.md)
- [Conversations — Delete](api-reference/conversations/delete.md) · [source](https://docs.phonic.ai/api-reference/conversations/delete.md)
- [Conversations — Evaluate](api-reference/conversations/evaluate.md) · [source](https://docs.phonic.ai/api-reference/conversations/evaluate.md)
- [Conversations — Get Analysis](api-reference/conversations/get-analysis.md) · [source](https://docs.phonic.ai/api-reference/conversations/get-analysis.md)
- [Conversations — Get](api-reference/conversations/get.md) · [source](https://docs.phonic.ai/api-reference/conversations/get.md)
- [Conversations — List Evaluations](api-reference/conversations/list-evaluations.md) · [source](https://docs.phonic.ai/api-reference/conversations/list-evaluations.md)
- [Conversations — List](api-reference/conversations/list.md) · [source](https://docs.phonic.ai/api-reference/conversations/list.md)
- [Conversations — Replay](api-reference/conversations/replay.md) · [source](https://docs.phonic.ai/api-reference/conversations/replay.md)
- [Projects — Create Eval Prompt](api-reference/projects/create-eval-prompt.md) · [source](https://docs.phonic.ai/api-reference/projects/create-eval-prompt.md)
- [Projects — List Eval Prompts](api-reference/projects/list-eval-prompts.md) · [source](https://docs.phonic.ai/api-reference/projects/list-eval-prompts.md)
- [Projects — List Evals](api-reference/projects/list-evals.md) · [source](https://docs.phonic.ai/api-reference/projects/list-evals.md)
- [Responses — Create](api-reference/responses/create.md) · [source](https://docs.phonic.ai/api-reference/responses/create.md)
- [Voices — Get](api-reference/voices/get.md) · [source](https://docs.phonic.ai/api-reference/voices/get.md)
- [Voices — List](api-reference/voices/list.md) · [source](https://docs.phonic.ai/api-reference/voices/list.md)
- [Voices — Preview](api-reference/voices/preview.md) · [source](https://docs.phonic.ai/api-reference/voices/preview.md)

### Guides

- [Evals Guide](docs/build/agents/evals_guide.md) · [source](https://docs.phonic.ai/docs/build/agents/evals_guide.md)
- [Multilingual Agents](docs/build/agents/multilingual.md) · [source](https://docs.phonic.ai/docs/build/agents/multilingual.md)
- [Prompting Guide](docs/build/agents/prompting_guide.md) · [source](https://docs.phonic.ai/docs/build/agents/prompting_guide.md)
- [Pronunciation Dictionary](docs/build/agents/pronunciation-dictionary.md) · [source](https://docs.phonic.ai/docs/build/agents/pronunciation-dictionary.md)
- [Replaying Conversations](docs/build/agents/replay.md) · [source](https://docs.phonic.ai/docs/build/agents/replay.md)
- [Supported Languages](docs/build/agents/supported_languages.md) · [source](https://docs.phonic.ai/docs/build/agents/supported_languages.md)
- [Template Variables](docs/build/agents/template-variables.md) · [source](https://docs.phonic.ai/docs/build/agents/template-variables.md)
- [Voices](docs/build/agents/voices.md) · [source](https://docs.phonic.ai/docs/build/agents/voices.md)
- [Built-in Tools](docs/build/tools/built_in_tools.md) · [source](https://docs.phonic.ai/docs/build/tools/built_in_tools.md)
- [Context Tools](docs/build/tools/context_tools.md) · [source](https://docs.phonic.ai/docs/build/tools/context_tools.md)
- [How Tools Execute](docs/build/tools/how_tools_execute.md) · [source](https://docs.phonic.ai/docs/build/tools/how_tools_execute.md)
- [Tools Overview](docs/build/tools/tools_overview.md) · [source](https://docs.phonic.ai/docs/build/tools/tools_overview.md)
- [WebSocket Tools](docs/build/tools/websocket_tools.md) · [source](https://docs.phonic.ai/docs/build/tools/websocket_tools.md)
- [Live Conversation WebSocket (Preview)](docs/build/with-web-sockets/live_websocket.md) · [source](https://docs.phonic.ai/docs/build/with-web-sockets/live_websocket.md)
- [Push to Talk](docs/build/with-web-sockets/push_to_talk.md) · [source](https://docs.phonic.ai/docs/build/with-web-sockets/push_to_talk.md)
- [connect() now returns a ReconnectableConversationsSocketClient](docs/build/with-web-sockets/via-web-sockets.md) · [source](https://docs.phonic.ai/docs/build/with-web-sockets/via-web-sockets.md)
- [Build Your First Agent](docs/get-started/build-your-first-agent.md) · [source](https://docs.phonic.ai/docs/get-started/build-your-first-agent.md)
- [Introduction](docs/get-started/overview.md) · [source](https://docs.phonic.ai/docs/get-started/overview.md)
- [Authenticating with JWTs](docs/platform/authentication/jw-ts.md) · [source](https://docs.phonic.ai/docs/platform/authentication/jw-ts.md)
- [Authentication](docs/platform/authentication/overview.md) · [source](https://docs.phonic.ai/docs/platform/authentication/overview.md)
- [Session Tokens](docs/platform/authentication/session-tokens.md) · [source](https://docs.phonic.ai/docs/platform/authentication/session-tokens.md)
- [Rate Limits](docs/platform/rate_limits.md) · [source](https://docs.phonic.ai/docs/platform/rate_limits.md)
- [Data Retention](docs/platform/retention.md) · [source](https://docs.phonic.ai/docs/platform/retention.md)

## Scope

Includes speech streaming, push-to-talk, live monitoring, agent configuration schema and voices, pronunciation and languages, prompt/context updates, tool behavior, authentication and tokens, conversation lifecycle and replay, evaluation, and retention.

Coding-agent installation instructions, the CLI guide, Amazon Connect, and audit-log administration were omitted from this provider-focused snapshot. The source index and API specifications retain the broader platform inventory.

The original download was pruned by 31 pages covering hosted-agent and stored-tool administration, workspace and external-storage administration, webhook deployment and notifications, LiveKit, Phonic-managed SIP, SDK installation, and unused MCP/webhook/transfer tool paths. Retained official pages and specifications are unmodified; removed paths are recorded in the manifest.

This directory is a documentation snapshot; no provider implementation or application changes are included.
