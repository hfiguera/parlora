# Incoming Twilio calls

`Parlora.Channels.Twilio` connects incoming calls using signed bidirectional
Twilio Media Streams. Your application owns the webhook listener, call admission,
customer identity, and policy for routing calls.

A phone session uses `audio_format: Parlora.AudioFormat.pcmu()` for mono G.711
μ-law at 8 kHz. All voice providers included with Parlora support this pipeline format.

## Integrate the webhook and stream

Mount `Parlora.Channels.Twilio.Endpoint.voice/2` on the incoming voice POST route:

```elixir
Parlora.Channels.Twilio.Endpoint.voice(conn,
  public_url: "https://voice.example.com/incoming",
  auth_token: auth_token,
  account_sid: account_sid,
  on_call: &MyApp.admit_twilio_call/1
)
```

The endpoint verifies the signed form before calling your admission function.
It must return `{:ok, wss_url}` for an authorized call. Use an expiring, single-use
path ticket to bind the media connection to that call and application user.
Twilio stream URLs cannot contain a query string.

On the media GET route, call `Parlora.Channels.Twilio.Endpoint.upgrade/2` with the
exact public WSS signing URL, auth token, and an `authorize:` callback. That
callback atomically consumes the ticket and returns `{:ok, socket_options}`:

```elixir
[
  channel_options: [account_sid: account_sid, call_sid: call_sid],
  start_session: fn channel ->
    MyApp.start_voice_session(
      channel: channel,
      audio_format: Parlora.AudioFormat.pcmu(),
      event_sink: self()
    )
  end
]
```

`MyApp.start_voice_session/1` supplies the provider, backend, and context policy
and returns `Parlora.start_session/1`'s result. The socket owns the transport;
its closure tears down the session. Mount these endpoints before a body parser
consumes the signed body. Signing URLs are explicit configuration, never inferred
from arbitrary forwarded headers.

## Playback and call lifecycle

The channel paces 20 ms media packets and uses Twilio marks to track remote
playback boundaries. Defaults are 200 ms local audio age, 500 ms output in flight,
and a two-second mark timeout. Configure `max_age_ms:`, `max_inflight_ms:`, and
`mark_timeout_ms:` in channel options when needed.

Clear discards pending output and waits for a fresh mark barrier. Older pending
marks become unknown because they may reflect audio played or cleared. A returned
mark does not establish human hearing or identify a business result as heard.
Output suppression and backend cancellation are separate operations.

Channel closure describes the media stream; it does not confirm the phone call
ended. The supplied voice endpoint places `<Hangup/>` after `<Connect>` in its
TwiML. Additional call control and public endpoint deployment belong to the host.

## Try OrderDesk

The example provides listeners for incoming calls and private review. Follow
[OrderDesk's Twilio setup](../examples/order_desk/README.md#incoming-twilio-calls)
for credentials, public webhook routing, and launch commands. Voice creates drafts;
only the separate browser confirmation flow saves delivery instructions.
