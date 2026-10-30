> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Introduction

> Phonic is the speech-to-speech model company.

Phonic is the speech-to-speech model company. Our models hear the caller’s audio directly and answer in natural speech, so the voice agents you build sound like a real conversation without trading away intelligence.

Our latest model, Phonic-1, is the most advanced speech-to-speech model for agentic tasks. Build, evaluate, and deploy agents on it with the API, our TypeScript and Python SDKs, the CLI, or the no-code agent builder, using the model ID `phonic-1`.

Every agent on Phonic-1 gets:

* **Tool calls while the caller is still talking**, so the answer is ready the moment they stop
* **Frontier intelligence in real time**, with sub-600ms latency from speech-in to speech-out, even through long, multi-step calls
* **Natural conversation** that picks up on tone and hesitation and handles interruptions and turn-taking, even on noisy phone lines
* **50+ languages**, with mid-conversation switching in the same voice
* **Accurate pronunciation** of URLs, emails, and alphanumerics
* **Enterprise readiness** with SOC 2 Type II, HIPAA (BAA available), zero data retention, a 99.9% uptime SLA, and deployment options from Phonic Cloud to self-hosted
* **One price per minute**, starting at \$0.07, with no LLM pass-throughs or per-token charges

## Get started

1. Sign up at [phonic.ai](https://phonic.ai).
2. Paste this prompt into your coding agent:

#### Claude Code

```text
Install the Phonic plugin from the Phonic-Co/skills marketplace
in Claude Code, including its skills and MCP connection.

Help me complete sign-in, then help me get started with Phonic.
```

#### Codex

```text
Install the skills from https://github.com/Phonic-Co/skills
and connect Codex to https://mcp.phonic.ai/mcp.

Help me complete sign-in, then help me get started with Phonic.
```

#### Cursor

```text
Install the skills from https://github.com/Phonic-Co/skills
and connect Cursor to https://mcp.phonic.ai/mcp.

Help me complete sign-in, then help me get started with Phonic.
```

#### Devin

```text
Help me install the Phonic plugin from
https://github.com/Phonic-Co/skills in Devin,
including its skills and MCP connection.

Help me complete sign-in, then help me get started with Phonic.
```

## Build

See the [API reference](/api-reference) for the full surface.

#### [TypeScript SDK](/docs/get-started/installation/typescript_sdk)

Install the SDK and make your first call.

#### [Python SDK](/docs/get-started/installation/python_sdk)

Install the SDK and make your first call.

#### [CLI](/docs/get-started/installation/cli)

Drive the API from your terminal.

## Example use cases

Phonic agents are already handling conversations like these in production:

#### Customer Service

Field support inquiries — order or booking changes, refunds, account changes, and escalation options.

#### Recruiting

Conduct structured real-time voice interviews, evaluates candidates against role fit, and fits into hiring workflows.

#### User Research

Conduct qualitative user interviews with open-ended discovery, neutral probing, and no leading.

#### Patient Intake

Run patient intake, confirms or reschedules appointments, and hands urgent cases off to a nurse line.

## Next Steps

Want to go deeper? Start here:

* [Conversations](../conversations/overview.md) — compare webhook and WebSocket conversations
* [Tools](/docs/build/tools/tools_overview) — learn about the tool types available on Phonic
* [Prompting guide](/docs/build/agents/prompting_guide) — write effective prompts for voice agents