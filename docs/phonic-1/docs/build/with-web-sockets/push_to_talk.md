> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

# Push to Talk

Push to talk (PTT) gives you manual control over when the user's audio is listened to, instead of relying on automatic turn-taking detection. This is useful for walkie-talkie-style interfaces, button-driven UIs, or any scenario where you want explicit control over turn-taking.

## How it works

In the default mode, Phonic automatically detects when the user starts and stops speaking. With push to talk enabled, **you** control this by sending `unmute` and `mute` messages over the WebSocket:

1. **Unmute** — signals that the user is about to speak. Interrupts the assistant and starts listening.
2. **Mute** — signals that the user has finished speaking. Stops listening and triggers the assistant's reply.

> **Warning**
>
> You must continue sending `audio_chunk` messages at all times, even while muted. Send either the real microphone audio or silent frames (zero-filled PCM). If you stop sending audio entirely, the connection may time out and the assistant will not respond.

## Setup

### 1. Enable push to talk in your config message

Set `push_to_talk` to `true` in the initial `config` message:

```json
{
  "type": "config",
  "agent": "my-agent",
  "push_to_talk": true
}
```

### 2. Send mute and unmute messages during the conversation

When the user presses the talk button, send an `unmute` message:

```json
{
  "type": "unmute"
}
```

When the user releases the button, send a `mute` message:

```json
{
  "type": "mute"
}
```

### 3. Keep streaming audio while muted

Even when the user is muted, you must keep sending `audio_chunk` messages. You can send either:

* **Silent frames** — zero-filled PCM data of the same format and chunk size you normally send
* **Real microphone audio** — the audio will be ignored by the speech model while muted, so it doesn't matter

```typescript
// Generate a silent audio chunk (example: ~100ms of 16-bit PCM at 44100 Hz)
const SILENT_CHUNK_SAMPLES = 4410; // 44100 * 0.1
const silentBuffer = Buffer.alloc(SILENT_CHUNK_SAMPLES * 2); // 2 bytes per 16-bit sample
const silentBase64 = silentBuffer.toString("base64");

// Send silent chunks on an interval while muted
const silenceInterval = setInterval(() => {
  phonicSocket.send(JSON.stringify({
    type: "audio_chunk",
    audio: silentBase64,
  }));
}, 100);
```

```python
import base64

# Generate a silent audio chunk (example: ~100ms of 16-bit PCM at 44100 Hz)
SILENT_CHUNK_SAMPLES = 4410  # 44100 * 0.1
silent_bytes = b"\x00" * (SILENT_CHUNK_SAMPLES * 2)  # 2 bytes per 16-bit sample
silent_base64 = base64.b64encode(silent_bytes).decode()

# Send silent chunks on an interval while muted
await socket.send_audio_chunk(AudioChunkPayload(audio=silent_base64))
```

## Example flow

Here is a typical sequence of messages for a push-to-talk conversation:

| Step | Direction       | Message       | Description                                                             |
| ---- | --------------- | ------------- | ----------------------------------------------------------------------- |
| 1    | Client → Server | `config`      | Connect with `push_to_talk: true`                                       |
| 2    | Client → Server | `audio_chunk` | Stream silent frames (user hasn't spoken yet)                           |
| 3    | Client → Server | `unmute`      | User presses talk button                                                |
| 4    | Client → Server | `audio_chunk` | Stream real microphone audio                                            |
| 5    | Client → Server | `mute`        | User releases talk button                                               |
| 6    | Server → Client | `audio_chunk` | Assistant responds with audio                                           |
| 7    | Client → Server | `audio_chunk` | Continue streaming silent frames while assistant speaks                 |
| 8    | Client → Server | `unmute`      | User presses talk button again (interrupts assistant if still speaking) |

> **Tip**
>
> See the [WebSocket API reference](/api-reference/conversations/conversations#send.mute) for full details on the `mute` and `unmute` message schemas.