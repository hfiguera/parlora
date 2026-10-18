> ## Documentation Index
> Fetch the complete documentation index at: https://developers.telnyx.com/llms.txt
> Use this file to discover all available pages before exploring further.

# Media Streaming over Websockets

> Stream call audio in real time over WebSockets with Telnyx Programmable Voice for transcription, AI integration, and bidirectional media.

Media Streaming provides instant access to your raw call media. With it, you can deliver
exceptional customer experiences—from unlocking new insights through sentiment analysis to providing fast resolutions using AI solutions. You can also bring your own AI engine and use real-time media streaming to connect it directly to call control, enabling custom AI-powered voice applications.

When your call is established, Telnyx takes the call media and forks it, so recipients receive the call simultaneously. The Telnyx network ensures that call media can be duplicated, delivered, analyzed, and returned in real-time. The secondary delivery recipient never occupies the call stream, so you never have to worry about degraded quality or dropped connections.

This guide covers how to set up media streaming over Websockets.

## Requesting streaming using Dial Command

The requesting dial command can be extended in the following way to request streaming using WebSockets:

```bash theme={null}
curl -X POST \
  --header "Content-Type: application/json" \
  --header "Accept: application/json" \
  --header "Authorization: Bearer YOUR_API_KEY" \
  --data '{
    "connection_id": "uuid", 
    "to": "+18005550199", 
    "from": "+18005550100", 
    "stream_url": "wss://yourdomain.com",
    “stream_track”:”inbound_track|outbound_track|both_tracks”}' \
  https://api.telnyx.com/v2/calls
```

The following additional attributes need to be added to the request:

* <code>stream\_url</code> - the destination address when the stream is going to be delivered.
* <code>stream\_track</code> - specifies which track should be streamed, with possible options:
  * <code>inbound\_track</code> (default)
  * <code>outbound\_track</code>
  * <code>both\_tracks</code>

As a response, a regular confirmation is sent:

```json theme={null}
{
  "data": {
    "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ",
    "call_leg_id": "2dc6fc34-f9e0-11ea-b68e-02420a0f7768",
    "call_session_id": "2dc1b3c8-f9e0-11ea-bc5a-02420a0f7768",
    "is_alive": false,
    "record_type": "call"
  }
}
```

## Requesting streaming using Answer Command

Using the same attributes as above, streaming can be requested while answering the call:

```bash theme={null}
curl -X POST \
  --header "Content-Type: application/json" \
  --header "Accept: application/json" \
  --header "Authorization: Bearer YOUR_API_KEY" \
  --data '{
    "client_state":"aGF2ZSBhIG5pY2UgZGF5ID1d",
    "command_id":"891510ac-f3e4-11e8-af5b-de00688a4901",
    "stream_url": "wss://yourdomain.com", 
    "stream_track":"inbound_track|outbound_track|both_tracks”}' \
  https://api.telnyx.com/v2/calls/{call_control_id}/actions/answer
```

In this case, confirmation that the call has been answered includes streaming details:

```json theme={null}
{
  "data": {
    "event_type": "call.answered",
    "id": "0ccc7b54-4df3-4bca-a65a-3da1ecc777f0",
    "occurred_at": "2018-02-02T22:25:27.521992Z",
    "payload": {
      "call_control_id":     "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ",
      "call_leg_id": "428c31b6-7af4-4bcb-b7f5-5013ef9657c1",
      "call_session_id": "428c31b6-abf3-3bc1-b7f4-5013ef9657c1",
      "client_state": "aGF2ZSBhIG5pY2UgZGF5ID1d",
      "connection_id": "7267xxxxxxxxxxxxxx",
      "from": "+35319605860",
      "state": "answered",
      "stream_url": "wss://yourdomain.com",
      "stream_track”:”inbound_track|outbound_track|both_tracks",
      "to": "+13129457420"
    },
    "record_type": "event"
  }
}
```

## Streaming process flow

When the WebSocket connection is established, the following event is being sent:

```json theme={null}
{ 
  "event": "connected", 
  "version": "1.0.0"
}
```

Before the stream begins, the <code>streaming.started</code> webhook is sent:

```json theme={null}
{
  "data": {
   "event_type": "streaming.started",
   "id": "0ccc7b54-4df3-4bca-a65a-3da1ecc777f0",
   "occurred_at": "2018-02-02T22:25:27.521992Z",
   "payload": {
     "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ",
     "stream_url": "wss://yourdomain.com"
    },
  "record_type": "event"
  }
}
```

An event over WebSockets which contains information in the **mediaFormat section** about the encoding and <code>stream\_id</code> that identifies a particular stream:

```json theme={null}
{ 
 "event": "start",  
 "sequence_number": "1", 
 "start": {
   "user_id": "3E6F995F-85F7-4705-9741-53B116D28237", 
   "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ", 
   "call_session_id": "ff55a038-6f5d-11ef-9692-02420aeffb1f",
   "from": "+13122010094",
   "to": "+13122123456",
   "tags": ["TAG1", "TAG2"], 
   "client_state": "aGF2ZSBhIG5pY2UgZGF5ID1d",
   "media_format": { 
     "encoding": "PCMU",
     "sample_rate": 8000, 
     "channels": 1 
   } 
 },
 "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC"
}
```

The following media events follow the start event:

```json theme={null}
{ 
 "event": "media",
 "sequence_number": "4",
 "media": { 
   "track": "inbound/outbound", 
   "chunk": "2",
   "timestamp": "5",
   "payload": "no+JhoaJjpzSHxAKBgYJDhtEopGKh4aIjZm7JhILBwYIDRg1qZSLh4aIjJevLBUMBwYHDBUsr5eMiIaHi5SpNRgNCAYHCxImu5mNiIaHipGiRBsOCQYGChAf0pyOiYaGiY+e/x4PCQYGCQ4cUp+QioaGiY6bxCIRCgcGCA0ZO6aSi4eGiI2YtSkUCwcGCAwXL6yVjIeGh4yVrC8XDAgGBwsUKbWYjYiGh4uSpjsZDQgGBwoRIsSbjomGhoqQn1IcDgkGBgkPHv+ej4mGhomOnNIfEAoGBgkOG0SikYqHhoiNmbsmEgsHBggNGDWplIuHhoiMl68sFQwHBgcMFSyvl4yIhoeLlKk1GA0IBgcLEia7mY2IhoeKkaJEGw4JBgYKEB/SnI6JhoaJj57/Hg8JBgYJDhxSn5CKhoaJjpvEIhEKBwYIDRk7ppKLh4aIjZi1KRQLBwYIDBcvrJWMh4aHjJWsLxcMCAYHCxQptZiNiIaHi5KmOxkNCAYHChEixJuOiYaGipCfUhwOCQYGCQ8e/56PiYaGiY6c0h8QCgYGCQ4bRKKRioeGiI2ZuyYSCwcGCA0YNamUi4eGiIyXrywVDAcGBwwVLK+XjIiGh4uUqTUYDQgGBwsSJruZjYiGh4qRokQbDgkGBgoQH9KcjomGhomPnv8eDwkGBgkOHFKfkIqGhomOm8QiEQoHBggNGTumkouHhoiNmLUpFAsHBggMFy+slYyHhoeMlawvFwwIBgcLFCm1mI2IhoeLkqY7GQ0IBgcKESLEm46JhoaKkJ9SHA4JBgYJDx7/no+JhoaJjpzSHxAKBgYJDhtEopGKh4aIjZm7JhILBwYIDRg1qZSLh4aIjJevLBUMBwYHDBUsr5eMiIaHi5SpNRgNCAYHCxImu5mNiIaHipGiRBsOCQYGChAf0pyOiYaGiY+e/x4PCQYGCQ4cUp+QioaGiY6bxCIRCgcGCA0ZO6aSi4eGiI2YtSkUCwcGCAwXL6yVjIeGh4yVrC8XDAgGBwsUKbWYjYiGh4uSpjsZDQgGBwoRIsSbjomGhoqQn1Ic"                        
 },
 "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC" 
}
```

The payload contains a base64-encoded RTP payload (no headers).

<Callout type="info">
  The order of events is not guaranteed and the chunk number can be used to reorder the events.
</Callout>

When the call ends, the **streaming.stopped** webhook is sent:

```json theme={null}
{
  "data": {
    "event_type": "streaming.stopped",
    "id": "0ccc7b54-4df3-4bca-a65a-3da1ecc777f0",
    "occurred_at": "2018-02-02T22:25:27.521992Z",
    "payload": {
      "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ",
      "stream_url": "wss://yourdomain.com"
    },
    "record_type": "event"
  }
}
```

And the stop event over WebSockets connection is sent:

```json theme={null}
{ 
 "event": "stop",
 "sequence_number": "5",
 "stop": {
  "user_id": "3E6F995F-85F7-4705-9741-53B116D28237",
  "call_control_id": "v2:T02llQxIyaRkhfRKxgAP8nY511EhFLizdvdUKJiSw8d6A9BborherQ"
  },
  "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC" 
}
```

<Callout type="info">
  Currently only one streaming/fork operation is supported per call. In case of requesting [media forking](/api-reference/call-commands/forking-start) the WebSocket stream will be stopped and replaced by a RTP connection.
</Callout>

## Bidirectional media streaming

### Sending RTP stream

The RTP stream can be sent to the call using websocket. The functionality can be enabled by setting `stream_bidirectional_mode` to `rtp`. For `dial` command it should look as follows:

```bash theme={null}
curl -X POST \
  --header "Content-Type: application/json" \
  --header "Accept: application/json" \
  --header "Authorization: Bearer YOUR_API_KEY" \
  --data '{
    "connection_id": "uuid", 
    "to": "+18005550199", 
    "from": "+18005550100", 
    "stream_url": "wss://yourdomain.com",
    "stream_track":"inbound_track|outbound_track|both_tracks"}',
    "stream_bidirectional_mode":"rtp" \
  https://api.telnyx.com/v2/calls
```

It can be requested using answer and streaming\_start commands in the same way.

The RTP streaming can be sent using media events:

```json theme={null}
{
  "event": "media",
  "media": {
    "payload": "your base64 encoded RTP stream"
  }
}
```

Provided chunks of audio can be in a size of 20 milliseconds to 30 seconds.

<Callout type="info">
  The number of bidirectional RTP streams per call is limited to 1.
</Callout>

#### RTP stream codec

There are the following codecs supported by bidirectional streaming:

* PCMU, 8 kHz (default)
* PCMA, 8 kHz
* G722, 8 kHz
* OPUS, 8 kHz, 16 kHz
* AMR-WB, 8 kHz, 16 kHz
* L16, 16 kHz

<Callout type="info">
  When the audio is sent using a different encoding than on the call, it will be transcoded, which may cause a degradation in quality.
</Callout>

<Callout type="info">
  The L16 codec provides improved support for AI voice agent integrations by offering reduced latency and eliminating transcoding overhead when interfacing with many AI platforms that natively support linear PCM audio.
</Callout>

The codec can be set when the streaming start is requested. For dial command, it looks as follows:

```bash theme={null}
curl -X POST \
  --header "Content-Type: application/json" \
  --header "Accept: application/json" \
  --header "Authorization: Bearer YOUR_API_KEY" \
  --data '{
    "connection_id": "uuid", 
    "to": "+18005550199", 
    "from": "+18005550100", 
    "stream_url": "wss://yourdomain.com",
    "stream_track":"inbound_track|outbound_track|both_tracks"}',
    "stream_bidirectional_mode": "rtp",
    "stream_bidirectional_codec": "PCMU|PCMA|G722|OPUS|AMR-WB|L16" \ 
  https://api.telnyx.com/v2/calls
```

### Sending media files

Media files can also be sent back to the call through the websocket. This is done similarly to the playback\_start command when using a base64-encoded mp3 file in the payload. Send a packet to the websocket connection as follows:

```json theme={null}
{
  "event": "media",
  "media": {
    "payload" : "your base64 encoded mp3 file"
  }
}
```

The payload, which is a base64-encoded mp3 file, will be played on the call. Multiple media messages will be queued and played in the order they were submitted.

Some limitations to be aware of:

* Media payloads can only be submitted once per second.
* Media must be base64 encoded mp3.

### Clear message

Sending a clear message will immediately stop the media playing on the stream and clear the media queue.

```json theme={null}
{
  "event": "clear"
}
```

### Mark message

Mark messages can be used to keep track of media ending on the stream:

* You can send a mark message to the stream after a media message.
* When the media immediately preceding the mark finishes you will receive the same mark back.

Example mark message sent to the stream:

```json theme={null}
{
  "event": "mark",
  "mark": {
    "name": "some_mark_name"
  }
}
```

Example mark message received from the stream:

```json theme={null}
{
  "event": "mark",
  "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
  "sequence_number": "5",
  "mark": {
    "name": "some_mark_name"
  }
}
```

Submitting marks when no audio is played or queued will result in them being immediately sent back. Similarly, the <code>clear</code> message will also result in all queued marks being sent back.

### DTMF message

In case of DTMF events on the call, the following message will be sent over websocket:

```json theme={null}
{
  "event": "dtmf",
  "stream_id": "32DE0DEA-53CB-4B21-89A4-9E1819C043BC",
  "occurred_at": "2025-06-05T08:54:19.698408Z",
  "sequence_number": "5",
  "dtmf": {
    "digit": "1"
  }
}
```

`occurred_at` field is a timestamp captured on the Telephony engine side. These are consumed as asynchronous events and in certain circumstances *may* arrive out of order. This field can be used to ensure proper order.

### Error message

In case of any case of error during media streaming, an error frame in the following format is sent:

```json theme={null}
{
  "event": "error",
  "payload": {
    "code": integer,
    "title": string,
    "detail": string
  },
  "stream_id": uuid
}
```

The list of the potential errors:

| Code   | Title                | Description                             |
| ------ | -------------------- | --------------------------------------- |
| 100002 | unknown\_error       | An unknown error occurred on the stream |
| 100003 | malformed\_frame     | Received frame was not formed correctly |
| 100004 | invalid\_media       | Media provided was not base64 encoded   |
| 100005 | rate\_limit\_reached | Too many requests                       |

### Example of integration

In the Telnyx GitHub repository there are several examples of integrations with external services using Media streaming:

* [Simple application that handles websocket streaming and provides the transcription of it using Node JS](https://github.com/team-telnyx/demo-node-telnyx/tree/master/websocket-demos/websocket)
* [Integration with DeepGram transcription engine using Node JS](https://github.com/team-telnyx/demo-node-telnyx/tree/master/websocket-demos/websocket-deepgram-transcription)
* [Integration with OpenAI speech-2-speech engine using Node JS](https://github.com/team-telnyx/demo-node-telnyx/tree/master/websocket-demos/websoket-openai-demo)
* [Pipecat Telnyx Chatbot in Python](https://github.com/pipecat-ai/pipecat-examples/tree/main/telnyx-chatbot)
