> ## Documentation Index
> Fetch the complete documentation index at: https://docs.rime.ai/llms.txt
> Use this file to discover all available pages before exploring further.

# Errors and limits

> Look up what a Prism error code, connection refusal, or close code means and what to do about it. The page also lists Prism's limits, fixes for common problems, and a checklist before production.

Most Prism errors do not end the conversation. Prism sends each error as an `error` event on the open connection, and refuses or drops only what the error names. Only a closed connection ends the conversation.

This page uses the event names of the WebSocket API. The Rime SDK reports the same codes as `fault.code`, on its `error` events and on `RimeRealtimeError`. The [Prism SDK reference](https://docs.rime.ai/api-reference/sdk/prism.md#errors) lists the SDK's other error classes.

## Read an error event

Prism sends this error when a `session.update` sets `temperature`, a field that Prism does not accept:

```json theme={null}
{
  "type": "error",
  "event_id": "evt_e4601e166bbbf36d",
  "error": {
    "type": "invalid_request_error",
    "code": "invalid_client_event",
    "message": "session.temperature is not a field of session.update",
    "param": "session.temperature",
    "event_id": "evt_temp",
    "correlation_id": "evt_e9f350c87c1051c6",
    "scope": "event",
    "owner": { "kind": "event", "event_id": "evt_temp" }
  }
}
```

Branch on `code` and `scope`, never on `message`. [Errors](https://docs.rime.ai/api-reference/prism/websocket.md#errors) in the WebSocket reference describes every field.

| Scope | What it affects | `owner` names |
| - | - | - |
| `event` | Prism refused or dropped one client event or one caller turn. Everything that Prism accepted before it stays in effect. | `event_id`, or `null` |
| `utterance` | Prism dropped some of the caller's input. | `item_id` |
| `response` | One reply. Its `response.done` follows, with `status` `failed` for every code except `no_audio`. | `response_id` |
| `tool_roundtrip` | The tool calls of one reply | `response_id` and `call_ids` |
| `session` | The whole conversation, which closes | Nothing more |

## Error codes

Each code below is an `invalid_request_error`, unless the table says `server_error`. A request that you send again on the same connection gets the same error, unless the table says to resend.

> [accordion] Find a code, A to Z
>
> [`call_id_in_use`](#history-and-playback-reports), [`capacity_exceeded`](#reply-failures), [`conflict`](#tool-calls), [`context_length_exceeded`](#reply-failures), [`deferred_capture_overflow`](#caller-speech), [`instructions_busy`](#requested-replies), [`invalid_audio`](#messages-and-audio), [`invalid_client_event`](#setting-up-the-session), [`invalid_content_index`](#history-and-playback-reports), [`invalid_event`](#messages-and-audio), [`invalid_instruction`](#requested-replies), [`invalid_response_cause`](#requested-replies), [`invalid_session`](#setting-up-the-session), [`invalid_tool_continuation`](#tool-calls), [`invalid_typed_input`](#requested-replies), [`invalid_voice`](#setting-up-the-session), [`item_id_in_use`](#history-and-playback-reports), [`item_not_found`](#history-and-playback-reports), [`item_too_long`](#history-and-playback-reports), [`no_audio`](#reply-failures), [`nudge_superseded`](#requested-replies), [`pending_speech_overflow`](#caller-speech), [`proactive_unavailable`](#requested-replies), [`response_cancel_not_active`](#requested-replies), [`response_superseded`](#requested-replies), [`response_timeout`](#reply-failures), [`session_not_initialized`](#setting-up-the-session), [`session_setting_fixed`](#setting-up-the-session), [`tool_call_not_found`](#tool-calls), [`tool_continuation_not_ready`](#tool-calls), [`tool_continuation_unavailable`](#tool-calls), [`tool_result_not_ready`](#tool-calls), [`tool_result_timeout`](#tool-calls), [`truncate_not_current`](#history-and-playback-reports), [`turn_failed`](#reply-failures), [`typed_turn_busy`](#requested-replies), [`typed_turn_superseded`](#requested-replies), [`unavailable`](#reply-failures), [`unsupported_modality`](#setting-up-the-session), [`voice_activity_detection_failed`](#ending-the-conversation), [`voice_required`](#setting-up-the-session)

### Setting up the session

| Code | What happened | What to do |
| - | - | - |
| `invalid_client_event` | A client event had an unknown field, or a field with the wrong type or an unknown value. `param` names the field. | Remove or fix the field. Prism changed nothing, so you can send a corrected `session.update`. |
| `invalid_session` | A tool in `session.update` had no function name, or a label in `prism_response_metadata` broke the [limits](#limits). `param` names the label. | Name every tool, and keep labels within the limits. |
| `unsupported_modality` | `modalities` did not include `"text"`, or was only `["text"]`. | Send `["text", "audio"]`, or omit `modalities`. |
| `invalid_voice` | The voice is not one of Prism's voices. | Use `aurora`, `wawona`, `brando`, or `astra`. |
| `voice_required` | After the update, spoken replies would have no voice. | Name a voice. |
| `session_not_initialized` | Audio or `response.create` arrived before Prism accepted a `session.update`. | Send `session.update` first, or fix what the `error` for a refused update names. Prism kept nothing. |
| `session_setting_fixed` | A later `session.update` gave a new value to `turn_detection.eagerness` or `turn_detection.prism_end_of_turn_timeout_ms`, which `param` names. Prism changed nothing, not even the other fields of the update. | Leave the field out, or send its current value. For a new value, start a new conversation on a new connection. |

### Messages and audio

| Code | What happened | What to do |
| - | - | - |
| `invalid_event` | The message was not a JSON object in a text frame, or its `type`, such as `input_audio_buffer.commit`, is not a client event. Or its `event_id` was not a string, for example `null`. | Send JSON text frames with a [client event](https://docs.rime.ai/api-reference/prism/websocket.md#client-events) type. Leave out `event_id`, or make it a string. |
| `invalid_audio` | `input_audio_buffer.append` had audio that is not base64. | Send standard, padded base64. |

### Requested replies

[`response.create`](https://docs.rime.ai/api-reference/prism/websocket#response-create) asks for a reply without new speech: a typed turn, a tool continuation, or a nudge, which makes Prism speak first.

| Code | What happened | What to do |
| - | - | - |
| `invalid_response_cause` | `response.create` had no `metadata.prism_cause` or an unknown one, or it was a nudge that named a parent reply. | Set `prism_cause` to `user_text`, `tool_continuation`, or `proactive`. |
| `invalid_typed_input` | The typed text was blank or over 4,000 code points, or the request had fields that a typed turn does not accept. Or its labels broke the limits. | Fix the request. |
| `invalid_instruction` | A nudge's `prism_instruction` was blank or over 4,000 code points, came with a top-level `instructions`, or came on another kind of request. Or its labels broke the limits. | Fix the request. |
| `typed_turn_busy` | A typed turn arrived while Prism was not [idle](https://docs.rime.ai/docs/prism/typed-turns.md#wait-until-prism-is-idle). | Resend after the next `prism.typed_input.ready`. Prism did not queue the turn. |
| `instructions_busy` | A nudge with an instruction, or a nudge that reports a tool result, arrived while Prism was not idle. | Resend after the next `prism.typed_input.ready`. |
| `proactive_unavailable` | A nudge without an instruction arrived while Prism was not idle. | Resend after the next `prism.typed_input.ready`. |
| `typed_turn_superseded` | The caller spoke before the reply to a typed turn started. Prism removed the typed text from the history. | If the text still matters, send it again. `scope` is `utterance`. |
| `nudge_superseded` | The caller spoke before an accepted nudge ran. Prism sends this error only for a nudge with an `event_id`. | Usually nothing. Prism replies to the caller instead. |
| `response_superseded` | The caller spoke before a requested reply, such as a tool continuation, started. Prism sends this error only for a request with an `event_id`. | Nothing. The new turn replaces the requested reply. |
| `response_cancel_not_active` | `response.cancel` found no running reply with that ID. | Nothing. You cannot cancel a reply that is still waiting to start. |

### Tool calls

| Code | What happened | What to do |
| - | - | - |
| `tool_call_not_found` | A tool result, or a nudge's `prism_call_id`, named a call that this conversation never made. Prism drops a tool result without an `event_id` and sends no error. | Do not send it again. Check the `call_id`. |
| `tool_result_not_ready` | A nudge's `prism_call_id` named a call that has no result yet. | Return the result first. |
| `conflict` | A second, different result arrived for a call that already had one. | Nothing. The first result stays. Prism acknowledges the same result if you send it again. |
| `invalid_tool_continuation` | A tool continuation had no `prism_parent_response_id`. | Name the reply that made the calls. |
| `tool_continuation_not_ready` | The continuation came before the parent reply's `response.done`, or before every call had a result. | Ask again when both are true. |
| `tool_continuation_unavailable` | The round already continued or made no calls, a new turn replaced it, or its wait ended. | Do not ask again. |
| `tool_result_timeout` | `server_error`, scope `tool_roundtrip`. Some results did not arrive within `prism_tool_waits.result_timeout_s`, 90 seconds after the parent's `response.done`. Prism recorded each missing call as an unknown outcome and closed the round. | Do not run the calls again automatically, because they may have completed. Prism still records a late result. |

[Tools](https://docs.rime.ai/docs/prism/tools.md) explains the whole round, and [Report a result later](https://docs.rime.ai/docs/prism/long-running-tasks.md#report-a-result-later) covers a late result.

### History and playback reports

| Code | What happened | What to do |
| - | - | - |
| `item_too_long` | A message in `conversation.item.create` was over 4,000 code points. | Shorten it. Tool results have no such limit, but they count toward the [context](#limits). |
| `item_not_found` | `conversation.item.truncate` did not name an assistant message of this conversation. Or `conversation.item.delete`, or the `previous_item_id` of `conversation.item.create`, named an item that this conversation never had. | For a playback report, use the `item.id` from the reply's `response.output_item.added`. For other requests, check the ID against the items that `prism.conversation.get` lists. |
| `item_id_in_use` | `conversation.item.create` gave the new item an `id` that an item in the conversation already has. Prism changed nothing. | Choose another `id`, or delete the old item first to free its `id`. |
| `call_id_in_use` | A past `function_call` in `conversation.item.create` reused the `call_id` of a call still in the conversation. A model call that you deleted keeps its `call_id` until its result arrives. Prism changed nothing. | Choose another `call_id`, or send the deleted call's result first to free its `call_id`. |
| `invalid_content_index` | `conversation.item.truncate` had a `content_index` other than 0. | Send 0. |
| `truncate_not_current` | The report named a reply from an earlier stretch of playback. | Report only the reply that was playing. |

### Caller speech

| Code | What happened | What to do |
| - | - | - |
| `pending_speech_overflow` | With this turn, the caller's speech that waits for a reply would go over 60 seconds. Prism discarded the turn. | Nothing for that turn. Earlier turns stay in the queue. |
| `deferred_capture_overflow` | `server_error`, scope `utterance`. Interruption was off, and the speech that Prism held during playback went past 30 seconds. Prism dropped the speech after that point. | Keep replies short, or turn interruption on. |

### Reply failures

Each of these codes has scope `response`, so the conversation continues. All codes except `context_length_exceeded` are a `server_error`. Only `capacity_exceeded`, `response_timeout`, and `unavailable` can succeed when you send the same request again.

| Code | What happened | What to do |
| - | - | - |
| `capacity_exceeded` | No reply slot became free within the 20-second first-output timeout. | Ask again after a short wait. If the error repeats, contact support. |
| `response_timeout` | The reply produced nothing for 20 seconds after it started, or for 30 seconds between two outputs. | Retry once. |
| `turn_failed` | The reply failed inside Prism. | Do not send the same request again. Report the `correlation_id`. |
| `context_length_exceeded` | The reply doesn't fit the [context](#limits). With [`truncation`](https://docs.rime.ai/api-reference/prism/websocket#when-the-conversation-outgrows-the-context) `"disabled"`, the whole conversation counts. With `"auto"`, it happens only when the instructions, tools, and this turn alone leave no room for the 512-token reply. The message gives the token counts. Every later reply fails the same way. | With `"disabled"`, delete earlier items with `conversation.item.delete`, set `truncation` to `"auto"`, or start a new conversation. With `"auto"`, shorten the instructions or tools. |
| `unavailable` | Prism is not ready, or is shutting down. | Ask again after a short backoff. If Prism closes the connection with 1001, reconnect. |
| `no_audio` | The reply produced words but no audio, and it still completes with its text. | Show the text. |

### Ending the conversation

| Code | What happened | What to do |
| - | - | - |
| `voice_activity_detection_failed` | `server_error`, scope `session`. Prism's speech detection failed. Without it, the caller's turns cannot end. Prism closes the connection with 1011. | Start a new conversation. |

## Connection refusals

Before the WebSocket opens, Prism can refuse the upgrade with an HTTP response, and no `error` event follows.

| HTTP status | Cause | What to do |
| - | - | - |
| `400` | The request is not a WebSocket upgrade. The body is `Expected WebSocket upgrade`. | Connect with a WebSocket client. |
| `401` | The upgrade request had no API key, or Prism did not accept the key. | Send `Authorization: Bearer` with a current [API key](https://docs.rime.ai/docs/api-authentication.md). |
| `404` | The path is not `/v1/realtime`. | Connect to `wss://prism.api.rime.ai/v1/realtime`. |
| `503` | Prism is not ready, is shutting down, has no room for another conversation, or could not check the API key. | Retry after a backoff. |

The [Rime SDK](https://docs.rime.ai/api-reference/sdk/prism.md#errors) raises `RimeAuthenticationError` for a `401` and `RimeUnavailableError` for the other refusals.

## Close codes

| Close code | Cause | What to do |
| - | - | - |
| `1000` "idle" | The conversation was idle for 5 minutes. A `session.idle_timeout` event comes first. | Reconnect when the caller returns. |
| `1001` | Prism is draining or shutting down. A draining server finishes the running reply but starts no other. | Reconnect after a short backoff. |
| `1011` | Speech detection failed. A `voice_activity_detection_failed` error comes first. | Reconnect. |
| None | Your client sent a message over 1 MiB, or Prism could not deliver a message to it for 10 seconds. Prism sends no `error` event and no close code, so client libraries report `1005` or `1006`. | Split large messages, and read events as they arrive. |

After a reconnect, send `session.update` again, and add the history that the agent needs with `conversation.item.create` messages, as [Start from an earlier conversation](https://docs.rime.ai/docs/prism/sessions.md#start-from-an-earlier-conversation) shows.

## Limits

| Limit | Value | When you exceed it |
| - | - | - |
| Message size | 1 MiB for each client message, one JSON object per text frame | Prism closes the connection with no `error` event and no close code. |
| Session setup | Up to 5 seconds from `session.update` to `session.updated` | If Prism accepts the `session.update`, it keeps the audio and `response.create` that you send while you wait. |
| One turn of speech | 55 seconds of continuous speech | Prism ends the turn at that point, as if the caller stopped, and replies to it. The rest of the speech is the next turn. |
| Speech waiting for a reply | 60 seconds, 1,920,000 bytes of audio | `pending_speech_overflow` |
| Speech held during playback | 30 seconds, while interruption is off | `deferred_capture_overflow`. Prism drops held speech under 100 ms as noise. |
| Text you send | 4,000 code points in a typed turn, a nudge instruction, or a history message | `invalid_typed_input`, `invalid_instruction`, or `item_too_long` |
| Labels | Up to 16 labels in `prism_response_metadata` or in the `metadata` of a `response.create`. Each key has up to 64 characters and does not start with `prism_`. Each value is a string of up to 512 characters. | `invalid_session`, or the refusal code of the request, such as `invalid_typed_input` |
| Reply length | 120 seconds of speech or 512 tokens of text. These are current values, and Rime may change them. | Prism cuts the reply. |
| Time to a reply's first output | 20 seconds, including any wait for a reply slot | `response_timeout`, or `capacity_exceeded` if the reply still waits for a slot |
| Time between a reply's outputs | 30 seconds | `response_timeout` |
| Tool results | 90 seconds from the parent reply's `response.done`, in `session.prism_tool_waits.result_timeout_s` | `tool_result_timeout` |
| Tool continuation | 60 seconds, from when the parent reply has ended and every result has arrived, in `continuation_timeout_s` | The round closes with no error. |
| Idle conversation | 5 minutes (300 seconds), even while your client streams silence. Any other client event, such as a nudge, resets the timer. | `session.idle_timeout`, then close code `1000` with reason `idle` |
| Delivering a server message | 10 seconds | Prism closes the connection with no `error` event and no close code. |
| Context | 65,536 tokens in all: instructions, tools, history, and tool results, plus 512 tokens kept for the reply | Prism leaves the oldest turns out of the prompt. With [`truncation`](https://docs.rime.ai/api-reference/prism/websocket#when-the-conversation-outgrows-the-context) `"disabled"`, every later reply fails with `context_length_exceeded` instead. If the instructions, tools, and the current turn alone don't fit, the reply fails with `context_length_exceeded` even with `"auto"`. |
| Conversation length | No time limit. The context limits how much of the conversation each reply sees. | Not applicable |

## Common problems

### Every audio message gets `session_not_initialized`

Prism has not accepted a `session.update` yet. Send one before any audio. If an `error` refused it, fix what that error names.

### Prism never answers the caller

Keep sending audio after the caller stops, because Prism finds the end of a turn from the silence. Also send 16 kHz audio, or let the Rime SDK convert it.

### Replies keep stopping partway

The caller's microphone can pick up Prism's voice from a speaker, and Prism can take that audio as an interruption. Each false interruption starts with `input_audio_buffer.speech_started` while a reply plays. Use headphones when you test, and echo cancellation in production.

### Replies sound too slow or too fast

Play Prism's audio at 24 kHz. A player set to 16 kHz plays it slow and low, and one set to 48 kHz plays it fast and high.

### Phone audio crackles

Send each reply to your telephony provider at a steady pace, as [Phone audio](https://docs.rime.ai/docs/prism/live-conversations.md#phone-audio) shows. Uneven pacing makes the caller hear crackles.

### A tool ran, but Prism said nothing

Prism does not continue after a tool result on its own. Ask for the continuation, as [Tools](https://docs.rime.ai/docs/prism/tools.md#run-each-call-and-continue-the-reply) shows.

### The connection closes without an error

Check for messages larger than 1 MiB or a server message that Prism could not deliver within 10 seconds. See [Close codes](#close-codes) for these connection limits. A close after `session.idle_timeout` is the 5-minute idle close.

## Report a problem

Email [support@rime.ai](mailto:support@rime.ai) these items from the failed conversation:

| What | Where |
| - | - |
| Request ID | `session.request_id` in `session.created`, or the `x-request-id` header of the upgrade response, which a refused upgrade has too |
| Session ID | `session.id` in `session.created` |
| Error IDs | `error.correlation_id`, and the `event_id` of the request it names |
| Error | The error `code` and `message` |
| Time | The UTC time of the failure |
| SDK | The SDK and its version, or "WebSocket API" |

Do not put your API key in the report.

## Before production

* Your API key is only on your backend.
* Your backend runs in or near US East, close to Prism.
* You pin your SDK version.
* Your client reads events on their own task, so a slow tool cannot delay them. The SDK ends the session when 256 events wait unread.
* Your application reports what the caller heard after each interruption.
* Each tool is safe to run once. Your code never runs a call again when its outcome is unknown.
* You log the request ID, the session ID, and the `correlation_id` of every error.
* Each error code has a handler.
* Your backend retries a `503` refusal after a backoff.


This documentation is built and hosted on [Mintlify](https://mintlify.com), a developer documentation platform.