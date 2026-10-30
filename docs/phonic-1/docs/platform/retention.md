> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Data Retention

> Control how long Phonic retains conversation transcripts, audio, and derived artifacts.

Retention is configured **per agent**, through the agent's
`data_retention_policy`. You can set it in the dashboard (agent → **Privacy**)
or through the API/SDKs on agent create, update, and upsert. There is no
workspace-wide switch and you don't need to contact Phonic to change it.

| Mode                          | `data_retention_policy`                                         | Transcripts & audio retained                                       | Conversation replay         | Async evals & extractions       |
| ----------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------- | ------------------------------- |
| **Standard** (default)        | `zero_data_retention: false` with `delete_after_hours: null`    | Indefinitely                                                       | Available                   | Available                       |
| **Custom retention**          | `zero_data_retention: false` with a `delete_after_hours` window | For the window you set, then hard-deleted                          | Available inside the window | Must complete inside the window |
| **Zero data retention (ZDR)** | `zero_data_retention: true`                                     | Deleted as soon as the conversation ends, can be stored externally | Unavailable                 | Synchronous only                |

> **Tip**
>
> Under ZDR you can attach an [external storage policy](#external-storage-policies)
> so Phonic delivers the conversation's audio and final snapshot to your own
> S3-compatible bucket instead of keeping a copy.

Standard and custom retention are the same policy shape — they differ only in
whether you set a `delete_after_hours` window — so you can move between them
with a single API call. ZDR is a distinct shape with no windows to set.

## Standard and custom retention

By default an agent keeps transcripts and audio recordings indefinitely, so you
can review past conversations, run evals after the fact, and debug agent
behavior over time.

To bound that, set how long after a conversation ends each artifact is kept. The
two windows are independent, so you can keep transcripts for 30 days while
deleting audio after 4 hours.

```typescript
await client.agents.update("support-agent", {
  project: "main",
  data_retention_policy: {
    zero_data_retention: false,
    transcripts: { delete_after_hours: 720 }, // 30 days
    audio_recordings: { delete_after_hours: 4 },
  },
});
```

```python
client.agents.update(
    "support-agent",
    project="main",
    data_retention_policy={
        "zero_data_retention": False,
        "transcripts": {"delete_after_hours": 720},  # 30 days
        "audio_recordings": {"delete_after_hours": 4},
    },
)
```

`delete_after_hours` is a whole number of hours greater than zero, or `null` to
keep that artifact indefinitely. Both `transcripts` and `audio_recordings` are
required when `zero_data_retention` is `false`.

The dashboard offers presets (4 hours, 24 hours, 7 days, 30 days, 90 days,
Never delete) but the API accepts any positive number of hours, and a
non-preset value set through the API is preserved and shown in the dashboard.

Deletion is scheduled when the conversation ends and runs once the window
elapses. Deleting **transcripts** also removes the derived text artifacts: tool
calls, evals, data extractions, transcript corrections, summaries, system
prompt and welcome message, template variables, and debug logs. Deleting
**audio recordings** removes the call `.wav` (including the redacted variant),
buffered audio chunks, and TTS generations.

Webhooks (`conversation.ended`, `conversation.analysis`,
`conversation.transferred`) fire normally and are not affected by the window. If
your pipeline needs data beyond the window, fetch and store it on your side
before it closes.

What we store while the data is retained:

* **Audio recordings**: full call audio in object storage.
* **Transcripts**: both raw and retranscribed text, per turn.
* **Derived artifacts**: conversation evals, data extractions, tool call logs,
  API request/response logs.

What we don't store:

* Audio buffers older than the call. The streaming buffer is discarded once the
  call ends; only the finalized recording is persisted.
* Customer secrets passed in tool call payloads (these are redacted before
  logging).

### Per-conversation policy

The STS WebSocket `config` message accepts the same `data_retention_policy`
object, which overrides the agent's policy for that conversation only. This is
useful when a single agent serves callers under different retention
requirements.

## Zero data retention (ZDR)

For the strictest privacy requirements. Set `zero_data_retention: true` and no
deletion windows are needed:

```typescript
await client.agents.update("support-agent", {
  project: "main",
  data_retention_policy: { zero_data_retention: true },
});
```

```python
client.agents.update(
    "support-agent",
    project="main",
    data_retention_policy={"zero_data_retention": True},
)
```

Deletion of transcripts and audio recordings is scheduled for the moment the
conversation ends, so conversation content does not outlive the call.

What's retained under ZDR:

* Conversation **metadata only**: `conversation_id`, `external_id`, start/end
  timestamps, duration, turn count, agent ID, and routing metadata (transfer,
  hangup reasons).
* Billing aggregates (call minutes, model usage).

What's never retained:

* Audio recordings.
* Transcripts (raw or retranscribed).
* LLM prompts and completions.
* Tool call inputs and outputs.

### What breaks under ZDR

ZDR disables features that depend on stored content:

| Feature                           | Behavior under ZDR                                                                                                      |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Conversation replay               | Unavailable.                                                                                                            |
| Async evals                       | Must run synchronously before the call ends, or are skipped.                                                            |
| Async data extractions            | Same: synchronous-only.                                                                                                 |
| Conversation history in dashboard | Metadata only, no transcript text.                                                                                      |
| Phonic support debugging          | Phonic engineers cannot view your call content.                                                                         |
| Certain models                    | Some upstream models do not offer a no-retention tier and are unavailable under ZDR. The dashboard marks these as such. |

Webhooks still fire. `conversation.ended` carries the full final transcript
in its payload, since that payload is the only opportunity for your systems to
receive it. Once the webhook is delivered, the content is discarded.

### Third-party provider behavior

Under ZDR, Phonic passes no-retention flags to all upstream providers:

* **OpenAI**: requests are sent with `store: false`. Phonic operates under
  OpenAI's Zero Data Retention agreement, so prompts and completions are not
  retained by OpenAI for abuse monitoring.
* **Deepgram**: speech-to-text requests use the no-storage configuration.
* **LiveKit / Twilio**: call recording is disabled at the transport layer.

A current list of which providers and which models offer ZDR-compatible tiers
is maintained on your workspace settings page.

### External storage policies

An external storage policy lets a ZDR agent deliver its final conversation
artifacts directly to your S3-compatible bucket. Phonic processes and uploads
the artifacts at the end of the conversation without retaining its own copy.
The policy belongs to a project and can be reused by multiple agents in that
project.

> **Note**
>
> External storage requires `zero_data_retention: true` and cannot be combined
> with `enable_redaction`. Redaction is post-call processing and requires Phonic
> to retain the conversation content.

To configure external storage:

1. In **Project settings**, create an external storage policy with your bucket's
   HTTPS endpoint, bucket name, region, optional key prefix, addressing style,
   and credentials. Credentials are encrypted and never returned.
2. In the agent's **Privacy** settings, enable zero data retention and select
   the policy.

You can also create and attach a policy through the API:

```typescript
await client.externalStoragePolicies.create({
  project: "main",
  name: "conversation_archive",
  endpoint_url: "https://storage.example.com",
  bucket: "conversation-audio",
  region: "us-east-1",
  key_prefix: "phonic/conversations",
  addressing_style: "auto",
  access_key_id: process.env.STORAGE_ACCESS_KEY_ID!,
  secret_access_key: process.env.STORAGE_SECRET_ACCESS_KEY!,
});

await client.agents.update("support-agent", {
  project: "main",
  data_retention_policy: {
    zero_data_retention: true,
  },
  external_storage_policy: "conversation_archive",
});
```

```python
import os

client.external_storage_policies.create(
    project="main",
    name="conversation_archive",
    endpoint_url="https://storage.example.com",
    bucket="conversation-audio",
    region="us-east-1",
    key_prefix="phonic/conversations",
    addressing_style="auto",
    access_key_id=os.environ["STORAGE_ACCESS_KEY_ID"],
    secret_access_key=os.environ["STORAGE_SECRET_ACCESS_KEY"],
)

client.agents.update(
    "support-agent",
    project="main",
    data_retention_policy={
        "zero_data_retention": True,
    },
    external_storage_policy="conversation_archive",
)
```

See the [external storage policy API](/api-reference/external-storage-policies/create)
and [agent update API](/api-reference/agents/update) for all options.

Each conversation is written under its conversation ID:

```text
<key_prefix>/<conversation_id>/conversation.wav
<key_prefix>/<conversation_id>/conversation.json
```

`conversation.wav` contains the call audio and `conversation.json` contains the
final conversation snapshot, including the transcript. Phonic uploads the JSON
file last, so you can treat it as the completion marker. Conversations without
audio contain only `conversation.json`.

Your bucket's access controls, lifecycle rules, and deletion policies determine
how long these copies are retained.

## Deletion on request

Regardless of retention policy, you can delete an individual conversation and
its transcripts and audio recordings:

```typescript
await client.conversations.delete(conversationId);
```

```python
client.conversations.delete(conversation_id)
```

See the [delete conversation API](/api-reference/conversations/delete).
Deletion is scheduled immediately and runs asynchronously, so the endpoint can
return before the data is gone. An active conversation cannot be deleted;
end it first.

> **Warning**
>
> Deletion is irreversible.

## Choosing a policy

* Keeping transcripts and audio indefinitely (the default) is appropriate while
  you iterate on agent prompts and review conversations.
* Set deletion windows if your compliance program requires a bounded retention
  period but you still want conversation history available for review. Windows
  are per artifact, so a short audio window with a longer transcript window is
  often the right trade.
* Use **ZDR** only if you've audited the feature trade-offs above and your
  security team requires that conversation content not outlive the call. Pair it
  with an external storage policy if you still need the artifacts.

For help selecting the right policy for your use case, contact your account team.