# OrderDesk example

OrderDesk is a complete application built with Parlora: browser voice, local audio,
incoming phone calls, order lookups, and draft delivery instructions backed by
SQLite. It uses fictional records. Jido is the default backend; Sagents and Legion
are optional alternatives. All audio passes through Parlora.

## Install from the checkout

Install Parlora's [runtime and native prerequisites](../../docs/beam-compatibility.md).
From the Parlora repository root:

```sh
mix hex.build --unpack --output examples/order_desk/vendor/parlora
cd examples/order_desk
mix deps.get --check-locked
```

The vendored package destination must not already exist. When changing Parlora,
refresh the vendored package before rebuilding this application. Dependencies,
build files, and SQLite records stay local to the example directory.

## Credentials

TypeSafe is OrderDesk's chosen interpretation service, rather than a Parlora
dependency. The terminal runner uses a deterministic policy and needs only the
API key for the voice provider when using Jido.

Supply credentials to the application's environment before launching. You need
one API key for the voice provider and, for browser/phone workflows, a TypeSafe key:

| Setting | Used for |
| --- | --- |
| `OPENAI_API_KEY` | Default OpenAI voice provider |
| `GEMINI_API_KEY` | Voice when `PARLORA_PROVIDER=gemini` |
| `XAI_API_KEY` | Voice when `PARLORA_PROVIDER=grok` |
| `PHONIC_API_KEY` | Voice when `PARLORA_PROVIDER=phonic` |
| `TYPESAFE_API_KEY` | Browser/phone intent and order interpretation |
| `SAGENTS_API_KEY` | Backend model when `PARLORA_BACKEND=sagents` |
| `LEGION_API_KEY` | Backend model when `PARLORA_BACKEND=legion` |

Use your normal secret management. The macOS launchers can use existing development
Keychain entries when an environment value is absent; supplying values explicitly
works across platforms. Parlora itself receives explicit provider options.

## Browser voice

```sh
scripts/browser.sh
```

Open **http://localhost:4000**, connect, allow microphone access, and wait for the
greeting. Try:

1. “Check order 123.”
2. “Actually, order 124.”
3. “What items are in that order?”
4. “Leave the delivery at reception.”

The last request creates a draft. Review the exact order and text on the page,
then confirm or reject it. Saying “yes” cannot save a change. The
[workflow guide](APPLICATION.md) explains persistence and confirmation.

The server binds to loopback. `PORT` and `BROWSER_ORIGIN` configure its listener
and exact page origin; keep them consistent. Calls default to 180 seconds with
four concurrent sessions. Before public deployment, add account authentication,
HTTPS, and the network's ICE/STUN/TURN configuration. The example has no account
login and is intended for local use.

## Select a voice provider or backend

```sh
PARLORA_PROVIDER=gemini scripts/browser.sh
PARLORA_PROVIDER=grok GROK_REASONING_EFFORT=high scripts/browser.sh
PARLORA_PROVIDER=phonic scripts/browser.sh
```

OpenAI uses `gpt-live-1`; Gemini uses `gemini-3.8-live`; Grok uses `grok-voice-3.0`.
Grok reasoning accepts `high` (default) or `none`.
Phonic uses the experimental `phonic-1` provider. On macOS, the launcher reads
`parlora-phonic-development` from Keychain when `PHONIC_API_KEY` is absent.
Refresh the vendored Parlora package first if it predates Phonic support.
Phonic uses PCM24 internally, including conversion for phone audio. A lost
provider connection ends the session; reconnect manually to start a new one.
The provider uses your Phonic workspace retention defaults. See the
[Phonic provider guide](../../docs/phonic-provider.md) for current limitations.

To select an optional backend, use the same selection when fetching dependencies
and launching:

```sh
PARLORA_BACKEND=sagents mix deps.get --check-locked
PARLORA_BACKEND=sagents scripts/browser.sh

# Or:
PARLORA_BACKEND=legion mix deps.get --check-locked
PARLORA_BACKEND=legion scripts/browser.sh
```

Backend text models default to `gpt-6-luna` with reasoning `none`. Set
`SAGENTS_MODEL` or `LEGION_MODEL` to configure the respective backend. This is
independent of the voice model. Jido's default action path needs no text model.
Provider/backend selections also apply to the local and phone launchers.

## Local microphone and speakers

```sh
scripts/voice.sh
```

The terminal runner needs only an API key for the selected voice provider when using Jido.
It has a smaller, deterministic policy for order status. Set `CPAL_HOST`, `CPAL_INPUT`,
and `CPAL_OUTPUT` to select devices, or use the defaults. Headphones help avoid
feedback; CPAL does not provide acoustic echo cancellation.

The terminal accepts `/status`, `/mute`, `/unmute`, `/stop`, `/resume`, `/mark`, and
`/quit`. `PARLORA_DEMO_SECONDS` controls its duration (default 120, maximum 1,800).

## Incoming Twilio calls

Supply `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_PHONE_NUMBER`, plus
keys for the selected voice provider and TypeSafe. Expose only the phone listener:

```sh
# Separate terminal:
ngrok http 4100 --inspect=false
```

Set the HTTPS origin printed by the tunnel, then launch from the example directory:

```sh
TWILIO_PUBLIC_URL=https://YOUR-NGROK-HOST \
ORDER_DESK_DATABASE="$PWD/data/twilio-demo.sqlite3" scripts/twilio.sh
```

Configure your Twilio number's incoming voice webhook as a POST to
`https://YOUR-NGROK-HOST/twilio/voice`. The application returns the signed stream
route. Open **http://localhost:4101/phone-review** for drafts; keep this review
listener private. `TWILIO_PORT` and `TWILIO_REVIEW_PORT` change the two ports.
The launcher requires an explicit database path; choose a fresh file for an isolated
demo. Incoming calls need neither a Voice SDK API key nor the SID of the phone number. On macOS,
supplying the listed environment variables bypasses Keychain lookup for them.
The [Twilio channel guide](../../docs/twilio-channel.md) explains host integration.

## Incoming Telnyx calls

Supply `TELNYX_API_KEY`, `TELNYX_PHONE_NUMBER`, `TELNYX_VOICE_API_CONNECTION_ID`,
and `TELNYX_WEBHOOK_PUBLIC_KEY`, plus keys for the voice provider and TypeSafe.

```sh
# Separate terminal:
ngrok http 4200 --inspect=false

# In the example directory, with the tunnel's HTTPS origin:
TELNYX_PUBLIC_URL=https://YOUR-NGROK-HOST \
ORDER_DESK_DATABASE="$PWD/data/telnyx-demo.sqlite3" scripts/telnyx.sh
```

Configure the Voice API connection's v2 webhook to
`https://YOUR-NGROK-HOST/telnyx/events`. Open
**http://localhost:4201/phone-review** for draft review and keep that listener
private. `TELNYX_PORT` and `TELNYX_REVIEW_PORT` change the ports. See the
[Telnyx guide](../../docs/telnyx-channel.md) for signed admission and stream setup.
Use a fresh database file for an isolated demo; an explicit path is required by
the launcher, even though other example entry points have a default database.

Phone calls use a demonstration customer identity. Caller ID does not authenticate
a customer. Use a dedicated development number/connection and configure its routing
through your provider account. Closing a media stream and ending the phone call
are separate operations.

## Persistence and deployment

`ORDER_DESK_DATABASE` selects the SQLite file (default `data/orders.sqlite3`).
Use a new filename for an isolated demo. Existing saved records are retained on
restart; interrupted calls and reconnects do not undo saved changes.

```sh
MIX_ENV=prod mix deps.get --check-locked
MIX_ENV=prod mix release
```

Build for the target OS/architecture and provide the required shared libraries.
The release contains compiled native bindings and does not need Mix or Rust at
runtime. Application startup opens no microphone or provider session. Listener
startup and real conversations are explicit application operations.
