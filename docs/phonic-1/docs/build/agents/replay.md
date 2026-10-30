> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Replaying Conversations

> Re-run a recorded turn — or a whole call — to test a prompt change before you deploy it.

Replay re-runs something that already happened, so you can test a change without placing a call. There are two levels:

|          | Endpoint                                                                           | What it re-runs                                                       | Returns                                                                             |
| -------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **Turn** | [`POST /conversation_items/{id}/replay`](/api-reference/conversation-items/replay) | One assistant turn, with the conversation up to that point as context | The response text (and tool calls) the assistant would have produced, synchronously |
| **Call** | [`POST /conversations/{id}/replay`](/api-reference/conversations/replay)           | The caller's recorded audio, through an agent, end to end             | A new conversation you can inspect, evaluate, and extract from                      |

Turn replay is the fast loop: it takes seconds, doesn't consume audio, and can generate up to 200 samples of the same turn in one request. This page covers it first.

## Replay a single turn

A conversation item is one turn. Only **assistant** items from **ended** conversations can be replayed.

### Getting a conversation item ID

> **Tip**
>
> **The easy way — copy it from the dashboard.** No code needed:
>
> 1. Open the conversation in the [Phonic dashboard](https://phonic.co).
> 2. Find the assistant turn you want to re-run.
> 3. Click the **⋯** menu at the right of that turn.
> 4. Choose **Copy item ID**.
>
> You now have a `conv_item_...` ID on your clipboard — paste it straight into the request below.

If you'd rather find turns in code — say you're replaying every turn of every call in a project — walk the conversation's items instead. Assistant items are the replayable ones, and each item's `id` is its conversation item ID:

```typescript
import { PhonicClient } from "phonic";
import type { Phonic } from "phonic";

const client = new PhonicClient({ apiKey: process.env.PHONIC_API_KEY });

// 1. Find a conversation (or use an ID you already have)
const list = await client.conversations.list({ project: "my-project" });
const conversationId = list.conversations[0].id;

// 2. Fetch it — the conversation carries its turns in `items[]`
const { conversation } = await client.conversations.get(conversationId);

// 3. Each assistant item is a replayable turn; `item.id` is the conversation item ID
const assistantTurns = conversation.items.filter(
  (item): item is Phonic.ConversationItem => item.role === "assistant",
);
const conversationItemId = assistantTurns[7].id; // e.g. the 8th assistant turn
```

```python
import os
from phonic import Phonic

client = Phonic(api_key=os.environ["PHONIC_API_KEY"])

# 1. Find a conversation (or use an ID you already have)
conversations = client.conversations.list(project="my-project").conversations
conversation_id = conversations[0].id

# 2. Fetch it — the conversation carries its turns in `items`
conversation = client.conversations.get(conversation_id).conversation

# 3. Each assistant item is a replayable turn; `item.id` is the conversation item ID
assistant_turns = [item for item in conversation.items if item.role == "assistant"]
conversation_item_id = assistant_turns[7].id  # e.g. the 8th assistant turn
```

### Replaying the turn

With the ID in hand, replay it. Omit `system_prompt` to re-run the turn exactly as it originally ran:

```typescript
const { responses } = await client.conversationItems.replay(conversationItemId, {
  num_responses: 100,
});
```

```python
responses = client.conversation_items.replay(
    conversation_item_id,
    num_responses=100,
).responses
```

**`cURL`**

```bash cURL
curl -X POST https://api.phonic.co/v1/conversation_items/conv_item_475ba813-.../replay \
  -H "Authorization: Bearer $PHONIC_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"num_responses": 100}'
```

Both body fields are optional:

| Field           | Default                                 | Notes                                                                                                                                                       |
| --------------- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `system_prompt` | The prompt the turn originally ran with | Set it to the candidate prompt you want to test. Everything else about the turn — the conversation history, the agent's tools, the model — stays as it was. |
| `num_responses` | `1`                                     | Up to `200`. Responses are sampled independently, so they will differ from each other.                                                                      |

The response is a flat list, one entry per sample:

```json
{
  "responses": [
    {
      "text": "Sure — I can help with that. What time works best?",
      "tool_calls": []
    }
  ]
}
```

> **Note**
>
> Tool calls in `tool_calls` are what the assistant *would* have invoked. Replay never actually calls your tools, so nothing in your systems is booked, charged, or transferred.

## Sampling: run the same turn 100 times

A single replay tells you what the assistant *can* say; a hundred replays tell you what it *usually* says. Because generation is sampled, one lucky response is not evidence that a prompt change worked — for a flaky behavior, the number you care about is the fraction of samples that get it right.

`num_responses: 100` takes roughly 15–20 seconds and typically comes back with close to 100 distinct texts. Score them yourself:

```typescript
const { responses } = await client.conversationItems.replay(conversationItemId, {
  system_prompt: candidatePrompt,
  num_responses: 100,
});

const ended = responses.filter((response) =>
  response.tool_calls.some(
    (call) => call.tool.name === "natural_conversation_ending",
  ),
).length;

console.log(`ended the call ${ended}/${responses.length} of the time`);
```

```python
responses = client.conversation_items.replay(
    conversation_item_id,
    system_prompt=candidate_prompt,
    num_responses=100,
).responses

ended = sum(
    any(call.tool.name == "natural_conversation_ending" for call in response.tool_calls)
    for response in responses
)

print(f"ended the call {ended}/{len(responses)} of the time")
```

Run the same measurement with `system_prompt` omitted to get the baseline for the prompt that actually ran, then compare. A useful workflow:

1. Find a turn that went wrong — often one flagged by a failing [eval prompt](/docs/build/agents/evals_guide).
2. Replay it 100× as-is. This is your baseline rate.
3. Replay it 100× with the candidate `system_prompt`. Keep the change if the rate moves.
4. [Update the agent](/api-reference/agents/update) and re-run your evals on new calls: a turn replay holds one turn's context fixed, so it cannot tell you what the change does to the rest of the call.

> **Tip**
>
> To iterate by hand rather than by script, use the **prompt playground** in the dashboard: in the conversations view, open the menu next to a turn. It calls the same endpoint.

## Replay a whole call

Turn replay holds the conversation history fixed. When a prompt change should alter the *course* of the call — the agent asks for the account number earlier, so every later turn differs — replay the conversation instead. This re-runs the caller's recorded audio through an agent as a real conversation:

```typescript
await client.conversations.replay(conversationId, { agent: "support-agent" });
```

```python
client.conversations.replay(conversation_id, agent="support-agent")
```

**`cURL`**

```bash cURL
curl -X POST https://api.phonic.co/v1/conversations/conv_a783813c-.../replay \
  -H "Authorization: Bearer $PHONIC_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent": "support-agent"}'
```

`agent` is optional and defaults to the agent the conversation originally ran with; point it at a different agent to test a full prompt or config change. The call returns as soon as the replay starts, and the replay shows up as a new conversation with `origin: "replay"` in the project it belongs to — list conversations to find it, then [evaluate](/api-reference/conversations/evaluate) or [extract](/api-reference/conversations/extract-data) against it like any other call.

Conversation replay does not need an agent-server or telephony leg — it works for conversations that ran over LiveKit or the WebSocket API as well as inbound and outbound phone calls.

## When replay is unavailable

| Status       | Meaning                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------ |
| `409`        | The conversation is still live. Wait for it to end.                                        |
| `422` (turn) | The item isn't an assistant turn, or the conversation's transcripts were deleted.          |
| `422` (call) | The conversation has no audio, its recordings were deleted, or it has no associated agent. |
| `429` (call) | Your concurrency limit is reached. Retry, or run replays with less overlap.                |
| `503` (call) | Not enough capacity to start the replay right now. Retry.                                  |

## Generate from inline history (experimental)

When the conversation was never recorded—or you want to edit its history—use [`POST /responses`](/api-reference/responses/create). Pass a system prompt and the conversation so far directly; no Phonic agent or conversation ID is required.

```typescript
const { responses } = await client.responses.create({
  system_prompt: "You are a concise, helpful assistant.",
  input: [{ role: "user", text: "Where should I get pizza near Union Square?" }],
});
```

```python
responses = client.responses.create(
    system_prompt="You are a concise, helpful assistant.",
    input=[{"role": "user", "text": "Where should I get pizza near Union Square?"}],
).responses
```

The endpoint is stateless: it does not create or update a conversation. `input` can also include assistant messages, historical tool calls, and their `tool_call_output` items. Tools returned in `tool_calls` are not executed; run them in your application, then append the assistant turn and matching tool output to a later request if you want to continue the exchange. See the [API reference](/api-reference/responses/create) for the complete request shape.

## Responses errors

| Status | Meaning                                                                      |
| ------ | ---------------------------------------------------------------------------- |
| `400`  | The request is invalid, such as malformed conversation or tool-call history. |
| `404`  | The experimental Responses API is not enabled for the workspace.             |
| `429`  | The workspace has exceeded its Responses API rate limit. Retry later.        |
| `502`  | The generation service returned an invalid response.                         |
| `503`  | The generation service is temporarily unavailable. Retry later.              |