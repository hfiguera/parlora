> For clean Markdown of any page, append .md to the page URL.
> For a complete documentation index, see https://docs.phonic.ai/llms.txt.
> For AI client integration (Claude Code, Cursor, etc.), connect to the MCP server at https://docs.phonic.ai/_mcp/server.

WebSocket conversations support the same features as webhook conversations but are much more flexible.
Because you will run your own server that manually forwards audio chunks between Phonic and your own audio interface,
you can implement offline tools and use your own audio interface, via telephony, web, or otherwise.

In this guide we'll demonstrate the basic mechanics of WebSocket conversations.
The example code for this guide is available
[here](https://github.com/Phonic-Co/phonic-examples/tree/main/03-conversation-websocket).

### Open a WebSocket connection to Phonic

The first step is to open a WebSocket connection to Phonic, which sends and receives various types of messages,
detailed [here](https://docs.phonic.ai/api-reference/conversations/conversations).

On the receiving side, the most important message is the `audio_chunk_response`, which contains the
Phonic-generated audio that your server will forward to your audio interface, along with its transcript.

Similarly, on the sending side, the most important message is the `audio_chunk`, which contains the user audio
that your server will forward to Phonic.

Here is an example implementation of this WebSocket connection:

```typescript
import { createNodeWebSocket } from "@hono/node-ws";
import { Hono } from "hono";
import type { WSContext } from "hono/ws";
import { PhonicClient } from "phonic";
import { phonicApiKey } from "./env-vars";

const app = new Hono();
const phonicClient = new PhonicClient({
  apiKey: phonicApiKey,
});

const { injectWebSocket, upgradeWebSocket } = createNodeWebSocket({ app });

app.get(
  "/ws",
  upgradeWebSocket(() => {
    let phonicSocket: Awaited<
      ReturnType<typeof phonicClient.conversations.connect>
    > | null = null;
    let streamSid: string | null = null;

    const sendToTwilio = (ws: WSContext, data: unknown) => {
      ws.send(JSON.stringify(data));
    };

    return {
      async onOpen(_, ws) {
        phonicSocket = await phonicClient.conversations.connect();

        phonicSocket.on("message", (message) => {
          if (streamSid && message.type === "audio_chunk") {
            sendToTwilio(ws, {
              event: "media",
              streamSid: streamSid,
              media: {
                payload: message.audio,
              },
            });
          }
        })

        await phonicSocket.sendConfig({
          type: "config",
          agent: "agent-websocket",
        };
      },

      async onMessage(event, ws) {
        const message = event.data;
        if (typeof message !== "string") return;
        const data = JSON.parse(message);
        switch (data.event) {
          case "start":
            streamSid = data.streamSid;
            break;

          case "media":
            if (phonicSocket && data.media.track === "inbound") {
              await phonicSocket.sendAudioChunk({
                type: "audio_chunk",
                audio: data.media.payload,
              });
            }
            break;

          case "stop":
            ws.close();
            break;
        }
      },

      onClose() {
        console.log("Twilio WebSocket closed");
        if (phonicSocket) {
          phonicSocket.close();
        }
      },
    };
  }),
);
```

```python
from fastapi import FastAPI, WebSocket
from phonic import AsyncPhonic, AudioChunkPayload
from phonic.conversations.socket_client import \
    ConversationsSocketClientResponse
from phonic.types.config_payload import ConfigPayload

app = FastAPI()
client = AsyncPhonic(api_key=os.getenv("PHONIC_API_KEY"))

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    queue: asyncio.Queue = asyncio.Queue()
    stream_sid = None

    async def receive_from_phonic(message: ConversationsSocketClientResponse):
        if stream_sid is not None and message.type == "audio_chunk":
            sending = {
                "event": "media",
                "streamSid": stream_sid,
                "media": {"payload": message.audio},
            }
            await websocket.send_json(sending)

    async def send_to_phonic():
        async with client.conversations.connect() as socket:
            socket.on("message", receive_from_phonic)
            asyncio.create_task(socket.start_listening())

            await socket.send_config(ConfigPayload(agent="agent-websocket"))

            while True:
                chunk = await queue.get()
                if chunk is None:
                    break
                await socket.send_audio_chunk(chunk)

    async def handle_websocket():
        process_task = asyncio.create_task(send_to_phonic())

        try:
            while True:
                data = await websocket.receive_json()
                match data["event"]:
                    case "start":
                        nonlocal stream_sid
                        stream_sid = data["streamSid"]
                    case "media":
                        payload = data["media"]["payload"]
                        await queue.put(AudioChunkPayload(audio=payload))
                    case "closed":
                        break

        finally:
            await queue.put(None)
            await process_task

    await handle_websocket()
```

### Open a connection with your audio interface

Now that your server is open and receiving messages from Phonic, you can use any audio interface for the user.
Here is a simple example using Twilio:

```typescript
import VoiceResponse from "twilio/lib/twiml/VoiceResponse";

app.post("/inbound", (c) => {
  const url = new URL(c.req.url);
  const response = new VoiceResponse();
  response.connect().stream({
    url: `wss://${url.host}/ws`,
  });
  return c.text(response.toString(), 200, { "Content-Type": "text/xml" });
});
```

```python
from fastapi import Response
from twilio.twiml.voice_response import Connect, VoiceResponse

@app.post("/inbound")
async def inbound() -> Response:
    voice_response = VoiceResponse()
    connect = Connect()
    connect.stream(url=f"wss://{os.environ['NGROK_URL'])}/ws")
    voice_response.append(connect)
    return Response(content=str(voice_response), media_type="application/xml")
```

> **Tip**
>
> See [here](https://github.com/Phonic-Co/phonic-examples/tree/main/03-conversation-websocket) for a complete code example.

### Automatic reconnection on abnormal disconnect

A live WebSocket connection can drop unexpectedly — most often when the socket is severed with no close handshake (surfaced to the client as close code **1006**), or when the edge proxy in front of Phonic redeploys and drains connections (the client is closed with **1012 "service restart"**, or sometimes **1001 "going away"** with reason `"restarting"`). By default a dropped conversation is lost and a new one must be started. Both the TypeScript and Python SDKs support automatic reconnection, which resumes the existing conversation seamlessly after a recoverable disconnect.

To enable it, pass `reconnectConversationOnAbnormalDisconnect: true` (TypeScript) or `reconnect_conversation_on_abnormal_disconnect=True` (Python) when creating the client:

```typescript
const phonicClient = new PhonicClient({
  apiKey: phonicApiKey,
  reconnectConversationOnAbnormalDisconnect: true,
});

// connect() now returns a ReconnectableConversationsSocket
const socket = await phonicClient.conversations.connect();

socket.on("message", (message) => {
  // Your message handler works the same as before. On a recoverable close
  // (1006, 1012, or 1001/"restarting"), the SDK automatically reconnects
  // using the conversation ID from the original session.
});
```

```python
client = AsyncPhonic(
    api_key=os.getenv("PHONIC_API_KEY"),
    reconnect_conversation_on_abnormal_disconnect=True,
)

# connect() now returns a ReconnectableConversationsSocketClient
async with client.conversations.connect() as socket:
    # Your message handler works the same as before. On a recoverable close
    # (1006, 1012, or 1001/"restarting"), the SDK automatically reconnects
    # using the conversation ID from the original session.
    ...
```

When enabled:

* On a recoverable close — **1006**, **1012**, or **1001** with reason `"restarting"` — the SDK opens a new WebSocket with the `reconnect_conv_id` query parameter set to the original conversation ID. A deliberate close (a bare 1001, or a normal 1000) ends the conversation as usual and does **not** trigger a reconnect.
* The server resumes the existing conversation and sends a `conversation_reconnected` message; audio streaming restarts automatically.
* Reconnection retries with exponential backoff, starting at 500 ms and doubling up to a 5 s cap. The server holds the conversation for approximately 30 seconds after the disconnect, so retries are sent up to 10 times or until the server expires the conversation, whichever occurs first. If the conversation is expired, the reconnect attempt receives a close code of **4800**.