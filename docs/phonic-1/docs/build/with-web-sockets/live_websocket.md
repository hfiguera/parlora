> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Live Conversation WebSocket (Preview)

The Live Conversation WebSocket provides real-time updates about an active conversation's state. It is a server-to-client only connection — the client does not send any messages after connecting.

## Endpoint

```
wss://api.phonic.ai/v1/conversations/{conversation_id}/live/ws
```

| Parameter         | Location | Description                           |
| ----------------- | -------- | ------------------------------------- |
| `conversation_id` | Path     | The ID of the conversation to observe |

## Authentication

Server-side clients can pass an API key in the
`Authorization: Bearer PHONIC_API_KEY` header. Browser clients should have
their backend create a short-lived session token, then pass it as a query
parameter:

```
wss://api.phonic.ai/v1/conversations/{conversation_id}/live/ws?session_token=ph_session_...
```

Never expose a Phonic API key in browser code. Session tokens are
organization-scoped and expire after their configured TTL.

Create the token with `conversation_ids` so that it covers only the
conversation being observed:

```bash
curl -X POST "https://api.phonic.ai/v1/auth/session_token" \
  -H "Authorization: Bearer $PHONIC_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "ttl_seconds": 300, "conversation_ids": ["conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c"] }'
```

Phonic enforces which conversations a token may observe. Confirm in your own
backend that the conversation belongs to the person asking before creating the
token.

## Connection flow

1. Connect to the WebSocket with valid credentials
2. Receive a `conversation-audio` message containing the live HLS playlist URL
3. Receive an initial `conversation-updated` message with the current conversation state
4. Continue receiving `conversation-updated` messages as the conversation progresses
5. Receive `conversation-ended` when the call finishes, while Phonic saves it
6. Receive `conversation-saved`, after which the socket closes normally

## Server-to-client messages

### `conversation-updated`

Sent whenever the conversation state changes. Contains the full conversation object.

The `conversation` object has the same shape as the [Conversation](/api-reference/conversations/list) returned by the REST API, with `is_live` always set to `true`.

**Session tokens receive a reduced object.** Because they are held by browsers,
they are sent only the conversation's own content and none of the agent's
configuration:

`id`, `external_id`, `origin`, `agent`, `items`, `text`, `summary`,
`duration_ms`, `started_at`, `ended_at`,
`assistant_end_conversation_signal_at`, `is_live`

Every other field is absent rather than null. The example below is what an API
key receives.

```json
{
  "type": "conversation-updated",
  "conversation": {
    "id": "conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c",
    "agent": {
      "id": "agent_12cf6e88-c254-4d3e-a149-a7f1bdd22783",
      "name": "support-agent",
      "is_deleted": false
    },
    "org_id": "org_01K1WB8NT3EJJ4ZRKJ6BQZPZPS",
    "project_id": "proj_ad0334f1-2487-4155-9df3-abd8129b29ad",
    "external_id": "call-123",
    "origin": "inbound",
    "generate_welcome_message": false,
    "is_welcome_message_interruptible": true,
    "welcome_message": "Hello! How can I help you today?",
    "template_variables": {},
    "input_format": "mulaw_8000",
    "output_format": "mulaw_8000",
    "background_noise_level": 0,
    "background_noise": null,
    "intelligence_level": "default",
    "text": "Hello! How can I help you today?\nHi, I need help with booking an appointment.\nOf course! I'd be happy to help.",
    "duration_ms": 12500,
    "summary": null,
    "boosted_keywords": [],
    "pronunciation_dictionary": [{"word": "Phuket", "pronunciation": "Poo-ket"}],
    "min_words_to_interrupt": 1,
    "default_language": "en",
    "additional_languages": [],
    "multilingual_mode": "request",
    "push_to_talk": false,
    "no_input_poke_sec": 30,
    "generate_no_input_poke_text": false,
    "no_input_poke_text": "Are you still there?",
    "no_input_end_conversation_sec": 180,
    "storage_key": null,
    "started_at": "2025-07-30T23:45:00.000Z",
    "ended_at": null,
    "task_results": null,
    "timezone": "America/Los_Angeles",
    "system_prompt": "You are a helpful support assistant.",
    "is_test": false,
    "is_live": true,
    "call_provider": "twilio_inbound_user",
    "from_phone_number": "+15551234567",
    "to_phone_number": "+15559876543",
    "twilio_call_sid": null,
    "created_by": null,
    "vad_min_silence_duration_ms": null,
    "assistant_end_conversation_signal_at": null,
    "retranscribed_text": null,
    "end_reason": null,
    "vad_info": { "events": [] },
    "annotations": {},
    "items": [
      {
        "id": "conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c-0",
        "item_idx": 0,
        "role": "assistant",
        "text": "Hello! How can I help you today?",
        "retranscribed_text": null,
        "duration_ms": 1800,
        "audio_speed": 1,
        "voice": null,
        "tool_call_ids": [],
        "transcript_corrections": [],
        "naturalness_report": null,
        "hallucination_report": null,
        "started_at": "2025-07-30T23:45:00.500Z",
        "assistant_chose_not_to_respond": false,
        "timings": {
          "phonic_api_output_to_modal_input": 120,
          "model_generation_time": 450,
          "phonic_api_output_to_first_audio_chunk": 570
        }
      },
      {
        "id": "conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c-1",
        "item_idx": 1,
        "role": "user",
        "text": "Hi, I need help with booking an appointment.",
        "retranscribed_text": null,
        "duration_ms": 2500,
        "audio_speed": null,
        "voice": null,
        "tool_call_ids": [],
        "transcript_corrections": [],
        "naturalness_report": null,
        "hallucination_report": null,
        "started_at": "2025-07-30T23:45:03.000Z",
        "assistant_chose_not_to_respond": false
      },
      {
        "id": "conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c-2",
        "item_idx": 2,
        "role": "assistant",
        "text": "Of course! I'd be happy to help.",
        "retranscribed_text": null,
        "duration_ms": 2100,
        "audio_speed": 1,
        "voice": null,
        "tool_call_ids": [],
        "transcript_corrections": [],
        "naturalness_report": null,
        "hallucination_report": null,
        "started_at": "2025-07-30T23:45:06.200Z",
        "assistant_chose_not_to_respond": false,
        "timings": {
          "phonic_api_output_to_modal_input": 95,
          "model_generation_time": 380,
          "phonic_api_output_to_first_audio_chunk": 475
        }
      }
    ]
  }
}
```

### `conversation-audio`

Sent after authentication and authorization succeed. The URL is stable and
contains no credentials.

```json
{
  "type": "conversation-audio",
  "url": "https://api.phonic.ai/v1/conversations/conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c/live/audio.m3u8"
}
```

Server-side clients fetch the playlist and every segment it references with
the same `Authorization: Bearer ...` header used for the WebSocket. Browser
clients add the same `session_token` query parameter to every playlist refresh
and segment request. The playlist is a growing HLS event playlist, typically a
few seconds behind the call. Caller audio is mixed into the left channel and
assistant audio into the right channel.

The playlist and segment endpoints are live-only. After `conversation-saved`,
use the regular Conversation API response and its final `audio_url`.

### `conversation-ended`

Sent when the call has ended and Phonic has started saving it. Keep the
WebSocket open until `conversation-saved` so you know when the saved
conversation is available.

```json
{
  "type": "conversation-ended"
}
```

### `conversation-saved`

Sent after the conversation has been stored. Phonic then closes the WebSocket
with close code `1000`.

```json
{
  "type": "conversation-saved"
}
```

### `error`

Sent on authentication failure, authorization failure, or other errors. The error may appear in `error.message` or the top-level `message` field.

```json
{
  "type": "error",
  "error": {
    "message": "Invalid token"
  }
}
```

```json
{
  "type": "error",
  "message": "Unauthorized access to conversation"
}
```

## Close codes

| Code   | Description                                    |
| ------ | ---------------------------------------------- |
| `1000` | Normal closure after the conversation is saved |
| `1008` | Authentication or authorization error          |

## Example usage

```typescript
import WebSocket from "ws";

const apiKey = "ph_...";
const conversationId = "conv_12cf6e88-c254-4d3e-a149-ddf1bdd2254c";

const ws = new WebSocket(
  `wss://api.phonic.ai/v1/conversations/${conversationId}/live/ws`,
  { headers: { Authorization: `Bearer ${apiKey}` } }
);

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);

  switch (data.type) {
    case "conversation-audio":
      console.log("Live audio playlist:", data.url);
      break;

    case "conversation-updated":
      console.log(`Conversation updated. (${data.conversation.items.length} turns)`)
      break;

    case "conversation-ended":
      console.log("Conversation ended; waiting for storage");
      break;

    case "conversation-saved":
      console.log("Conversation saved");
      ws.close();
      break;

    case "error":
      console.error("Error:", data.error?.message ?? data.message);
      ws.close();
      break;
  }
};
```

## Playing live audio in a browser

Browsers generally need an HLS client such as [HLS.js](https://github.com/video-dev/hls.js)
because a native `<audio src="...">` request cannot add a session token to
playlist refreshes and segment requests.

```bash
npm install hls.js
```

```typescript
import Hls from "hls.js";

const audio = document.querySelector("audio");
let sessionToken = await getSessionTokenFromYourBackend();
const liveWebSocketUrl = new URL(
  `wss://api.phonic.ai/v1/conversations/${conversationId}/live/ws`
);
liveWebSocketUrl.searchParams.set("session_token", sessionToken);
const liveWebSocket = new WebSocket(liveWebSocketUrl);

if (!audio || !Hls.isSupported()) {
  throw new Error("HLS.js playback is not supported in this browser");
}

const hls = new Hls({
  fetchSetup(context, initParams) {
    const authenticatedUrl = new URL(context.url);
    authenticatedUrl.searchParams.set("session_token", sessionToken);
    return new Request(authenticatedUrl, initParams);
  },
});

liveWebSocket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);

  if (message.type === "conversation-audio") {
    hls.loadSource(message.url);
    hls.attachMedia(audio);
  }
});
```

The session token must remain valid for the WebSocket, playlist, and segment
requests. For longer conversations, renew it through your backend before it
expires and update the token used by your HLS request hook.

> **Warning**
>
> Do not embed a Phonic API key in browser code. Create the short-lived session
> token on a trusted backend. For an API-key integration, consume or proxy the
> stream from your trusted backend.

## Live audio errors

Playlist and segment requests can return:

| Status | Meaning                                                                                |
| ------ | -------------------------------------------------------------------------------------- |
| `401`  | Authentication is missing or invalid                                                   |
| `404`  | The conversation is unavailable, belongs to another organization, or is no longer live |
| `410`  | Audio recordings for the conversation were deleted                                     |