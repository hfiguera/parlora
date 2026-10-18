# Incoming Telnyx calls

`Parlora.Channels.Telnyx` connects incoming Voice API / Call Control calls using
bidirectional PCMU media. The host owns signed webhook admission, call identity,
stream authorization, REST command workers, and policy for routing calls.

Use `audio_format: Parlora.AudioFormat.pcmu()` for mono μ-law at 8 kHz. The voice provider,
backend, and context policy can each be selected independently of the phone channel.

## Webhook admission

Mount `Parlora.Channels.Telnyx.Endpoint.webhook/2` **before** a JSON body parser:

```elixir
Parlora.Channels.Telnyx.Endpoint.webhook(conn,
  public_key: verification_key,
  on_event: &MyApp.admit_telnyx_event/1
)
```

The endpoint verifies Ed25519 signatures over the timestamp and exact raw body,
then invokes the admission callback. Atomically authorize and deduplicate the
event and enqueue admitted work. The callback returns one of these values;
return `:ok` for an admitted duplicate too:

| Callback return | HTTP status | Response body |
| --- | --- | --- |
| `:ok` | 200 | `"OK"` |
| `{:error, :backpressure}` | 503 | `"Unavailable"` |
| `{:error, reason}` for any other reason | 403 | `"Forbidden"` |

The 503 response allows Telnyx to retry delivery. Run REST commands in supervised
workers, not in the callback. Signature freshness does not replace event deduplication.

## Answer and start the media stream

After an answered event, start streaming with explicit settings:

```elixir
parameters = Parlora.Channels.Telnyx.Commands.stream_options(wss_url, stream_token)

Parlora.Channels.Telnyx.Commands.execute(
  :streaming_start, call_control_id, command_id, parameters, api_key: key
)
```

The helper selects inbound PCMU, bidirectional RTP mode, 8 kHz, and the caller's
`self` leg. Use a stable command ID to reconcile retries. The command client also
supports `:answer`, `:streaming_stop`, and `:hangup`. HTTP acceptance is separate
from signed events reporting call progress. Defaults are three attempts and an eight-second
overall deadline; uncertain results require host reconciliation.

Mount `Parlora.Channels.Telnyx.Endpoint.upgrade/2` on the media route. Its
`authorize: fn conn, token -> ... end` callback must atomically consume an
expiring token bound to the call from the `x-telnyx-streaming-auth-token` header and
return `{:ok, socket_options}`. Use constant-time token comparison. The API key
is never a stream credential; an echoed token in a media frame is insufficient.

Socket options include authorized `channel_options` and a `start_session:` factory
that supplies the channel, PCMU format, and `event_sink: self()` to your normal
session setup. See `Parlora.Channels.Telnyx` for required call identifiers.

## Audio and lifecycle

Input has a 40 ms reorder window and finite chunk bounds. Local audio queues are
200 ms, output in flight is bounded to 500 ms, and marks expire after two seconds.
Short output tails are padded with PCMU silence to the carrier's 20 ms minimum.
Stale unsent output is discarded with a discontinuity event; missing marks fail
at the finite playback acknowledgment deadline.

Clear waits for a new mark barrier; older marks remain unknown. Stream closure
releases media resources and does not itself prove call hangup. Backend work and
business effects have their own cancellation and reconciliation rules.

## Try OrderDesk

See [OrderDesk's Telnyx setup](../examples/order_desk/README.md#incoming-telnyx-calls)
for the webhook listener, credentials, tunnel, and private review page. Caller ID
is not customer authentication. Voice can draft delivery instructions; saving
requires the separate browser confirmation flow.
