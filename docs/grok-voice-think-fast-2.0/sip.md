#### Speech to Speech API

# SIP Phone Calls

SIP lets you route PSTN, contact-center, or PBX calls into a Speech to Speech API session.

### 1. Register the phone number

Create a Direct SIP phone number and include the webhook details that should receive incoming-call events. Use `origin: "byo_trunk"` for a customer-owned number. Provisioning SpaceXAI phone numbers via API is not supported. SpaceXAI returns the webhook signing secret in the response.

Choose one SIP authentication method.

The response includes a signing secret after you register the phone number. Store it securely; SpaceXAI returns it only once.

Configure your carrier or PBX to route calls to:



If you provide `allowed_addresses`, make sure the list contains your provider's SIP signaling CIDR ranges. If you provide SIP digest credentials, configure your carrier with the same username and password; SpaceXAI never returns the password after creation.

### 2. Handle the incoming-call webhook

When a caller dials the number, SpaceXAI sends a signed `realtime.call.incoming` webhook to the webhook URL. Verify the `webhook-id`, `webhook-timestamp`, and `webhook-signature` headers using the signing secret returned after you register the phone number, then read `data.call_id` from the payload.

The webhook has this shape:

```json
{
  "object": "event",
  "id": "evt_123",
  "type": "realtime.call.incoming",
  "created_at": 1750000000,
  "data": {
    "call_id": "00000000-0000-0000-0000-000000000000",
    "sip_headers": [
      { "name": "From", "value": "+14155550100" },
      { "name": "To", "value": "+18005550199" }
    ],
    "metadata": {}
  }
}
```

### 3. Join the call over WebSocket

Open `wss://api.x.ai/v1/realtime?call_id={call_id}` with your xAI API key. Then send `session.update` to configure the voice agent for this call, followed by `response.create` when the agent should begin speaking.

After connecting, the WebSocket behaves like any other Speech to Speech API session. The SIP caller's audio is bridged into the session, and assistant audio is played back to the caller.

```python customLanguage="pythonWithoutSDK"
import asyncio
import json
import os
import websockets

async def handle_sip_call(call_id: str):
    async with websockets.connect(
        f"wss://api.x.ai/v1/realtime?call_id={call_id}",
        additional_headers={"Authorization": f"Bearer {os.environ['XAI_API_KEY']}"},
    ) as ws:
        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "voice": "eve",
                "instructions": "You are a helpful phone support agent.",
                "turn_detection": {"type": "server_vad"},
            },
        }))
        await ws.send(json.dumps({"type": "response.create"}))

        async for msg in ws:
            event = json.loads(msg)
            print(event["type"])

asyncio.run(handle_sip_call("00000000-0000-0000-0000-000000000000"))
```

```javascript customLanguage="javascriptWithoutSDK"
import WebSocket from "ws";

const callId = "00000000-0000-0000-0000-000000000000";
const ws = new WebSocket(`wss://api.x.ai/v1/realtime?call_id=${callId}`, {
  headers: { Authorization: `Bearer ${process.env.XAI_API_KEY}` },
});

ws.on("open", () => {
  ws.send(JSON.stringify({
    type: "session.update",
    session: {
      voice: "eve",
      instructions: "You are a helpful phone support agent.",
      turn_detection: { type: "server_vad" },
    },
  }));
  ws.send(JSON.stringify({ type: "response.create" }));
});

ws.on("message", data => {
  const event = JSON.parse(data.toString());
  console.log(event.type);
});
```

## Remove a phone number

Delete the registration when SpaceXAI should stop answering the number. `phone_number_id` is in the create response. To find it later, list the team's numbers and match `phone_number`:

```bash customLanguage="bash"
curl "https://api.x.ai/v2/phone-numbers" \
  -H "Authorization: Bearer $XAI_API_KEY"
```

```bash customLanguage="bash"
curl -X DELETE "https://api.x.ai/v2/phone-numbers/phone_abc123" \
  -H "Authorization: Bearer $XAI_API_KEY"
```

A successful delete returns `204` with an empty body. SpaceXAI deletes that number's inbound SIP trunk and dispatch rule. The webhook record stays, and the phone number stays in your carrier account. A SpaceXAI-provisioned number is not deleted; the API returns `403`. See [Delete phone number](/developers/rest-api-reference/inference/voice#delete-phone-number).

## Call control

Use `refer` to transfer the caller to another PSTN or SIP destination. The request blocks until the transfer resolves; the HTTP status reports whether the destination answered. See [FAQ](#faq) for status codes, failed-transfer session behavior, and conversation resumption.

```bash customLanguage="bash"
curl -X POST "https://api.x.ai/v1/realtime/calls/$CALL_ID/refer" \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"target_uri": "sip:agent@example.com"}'
```

Use `hangup` when your application should end the call:

```bash customLanguage="bash"
curl -X POST "https://api.x.ai/v1/realtime/calls/$CALL_ID/hangup" \
  -H "Authorization: Bearer $XAI_API_KEY"
```

## DTMF phone keypresses

When using the Speech to Speech API over SIP, phone keypresses (DTMF tones) are automatically buffered and flushed to the model as text input. The client receives `input_audio_buffer.dtmf_event_received` events as an audit trail of each keypress.

### Flush triggers

Buffered digits are submitted to the model when any of the following occurs:

* The user presses `#` (submit key)
* 2.5 seconds of idle time after the last keypress
* The user begins speaking (preempts the digit buffer)

### Audit event

Each keypress is reported to the client WebSocket:

```json customLanguage="json"
{
  "type": "input_audio_buffer.dtmf_event_received",
  "event": "5",
  "received_at": 1730000000
}
```

> [!NOTE]
>
> DTMF is only available on SIP sessions — it is not emitted on direct WebSocket connections.

## Telephony providers

In every provider, the destination is the SpaceXAI SIP URI for your registered number:



Replace `{number}` with your Direct SIP phone number. If you configured `allowed_addresses` when registering the number, include your provider's SIP signaling CIDR ranges.

### Twilio

1. In the Twilio Console, go to **Voice** → **Elastic SIP Trunking** and create a trunk.
2. Open the trunk's **Origination** settings and add this origination URI: `sip:{number}@sip.voice.x.ai;transport=tls`.
3. Assign a Twilio phone number to the trunk, or purchase a new number and attach it.
4. If your application transfers calls mid-session, enable call transfer on the trunk.

### Telnyx

1. In the Telnyx Portal, go to **Voice Suite** → **SIP Trunking** and create an FQDN SIP Connection.
2. In **Authentication and Routing**, add `sip.voice.x.ai` as the primary FQDN on port `5060` with record type `A`.
3. In **Inbound settings**, set the destination number format to **E.164**.
4. Enable at least one supported codec: G.711 μ-law, G.711 A-law, or G.722.
5. Assign a phone number to the SIP Connection.

### Plivo

1. In the Plivo Console, go to **SIP Trunking** and create a SIP trunk.
2. Choose **Inbound**, then create a new URI with FQDN `sip.voice.x.ai`.
3. Link an existing phone number to the trunk, or buy a new number and attach it.

### Bring Your Own SIP Provider

1. In your carrier, contact center, or PBX, create an outbound route or SIP trunk.
2. Set the destination to `sip:{number}@sip.voice.x.ai;transport=tls`.

## FAQ

These answers cover the Speech to Speech API SIP path: transfer success and failure with reason codes, what happens when a transfer fails, and how to continue a conversation on a later SIP call.

### How do I get transfer success or failure with a reason code?

There is no separate WebSocket transfer event. `POST /v1/realtime/calls/{call_id}/refer` returns the outcome synchronously.

A `200` with an empty JSON body (`{}`) means the transfer completed: the REFER succeeded and the destination answered, not merely that the REFER was accepted or that the destination started ringing.

Downstream SIP rejections return `502` with the carrier's SIP status in the body:

```json customLanguage="json"
{
  "error": "transfer rejected by downstream: SIP 403 Forbidden"
}
```

Other statuses are also possible:

| Status | Meaning |
| --- | --- |
| `400` | `target_uri` is not a `tel:` or `sip:` URI |
| `404` | No SIP participant on this call |
| `502` | Transfer rejected by downstream; the body includes the SIP code and reason when available |
| `504` | Transfer timed out |
| `500` | Internal error |

### Does the session stay usable if a transfer fails?

Yes. While the REFER is pending, the WebSocket stays open and the caller hears dialtone. After a `502`, that same realtime session stays connected. The failed transfer is a no-op on the SpaceXAI side: the caller remains on the call, and the agent can keep talking.

This path does not automatically start a new session or inject a failure-reason prompt. If the agent should tell the caller why the transfer failed, read the `refer` HTTP response and continue on this session, or resume later as below.

### Can I reattach a resumed conversation to a new SIP call?

[Session resumption](/developers/model-capabilities/audio/speech-to-speech#session-resumption) caches transcripts and tool results so a later SIP call can continue the same conversation. You must opt in on both the original session and the resuming session. History expires after 30 minutes of inactivity.

1. On the first call, open `wss://api.x.ai/v1/realtime?call_id={call_id}` and immediately send `session.update` with `resumption.enabled` set to `true`. Save that `call_id`.
2. On the later call, open `wss://api.x.ai/v1/realtime?call_id={new_call_id}&conversation_id={saved_call_id}` and send the same `session.update` again. That restores the prior turns and keeps saving for future reconnects.
3. There is no dedicated resumption-complete event. Restore happens as soon as that `session.update` is processed; replayed turns arrive as `conversation.item.created` events.

```json customLanguage="json"
{
  "type": "session.update",
  "session": {
    "resumption": { "enabled": true }
  }
}
```

### Can I transfer to a Twilio SIP Domain?

Yes. A `sip:` `target_uri` is forwarded as the SIP `Refer-To` value, including URI parameters used to route into a Twilio Programmable Voice SIP Domain or conference. Custom SIP headers are not sent on the REFER.
