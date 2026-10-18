# LAN STUN/TURN validation

This is deployment tooling, not a Parlora dependency. The tested Linux host runs
**coturn 4.18.0**, built with **libevent 2.1.12-stable** and its existing OpenSSL
3.0.13 development files. `install.sh` pins and checks both source archive hashes.
It installs under `~/.local/share/parlora-turn` without sudo, Docker, system package
changes or firewall/router changes. Build requirements: a C compiler, make,
OpenSSL development headers, curl, tar, pkg-config, Python 3 and a user systemd
manager for the service. See [coturn](https://github.com/coturn/coturn) and its
[configuration reference](https://github.com/coturn/coturn/blob/4.18.0/README.turnserver).

## Install and manage on Linux

```sh
sh validation/turn/install.sh
python3 validation/turn/configure.py --listen 10.0.0.3 --peer 10.0.0.2
systemctl --user status parlora-turn.service
```

Use the addresses of your actual test hosts. The configured instance binds
**10.0.0.3:3478 UDP/TCP**, with UDP relay ports **49160–49191**. It allows relay
traffic only to the Linux host and the specified Mac peer. TURN requires
HMAC-based credentials; STUN Binding remains available without authentication.
The service limits allocations to 16 overall, eight per username, and bandwidth
to 128,000 bytes/second per allocation. Browser calls remain bounded by the host's
180-second session limit. No Internet deployment is configured.

`configure.py` creates a random shared secret in `etc/auth-secret`, a private
`etc/turnserver.conf`, and `~/.config/systemd/user/parlora-turn.service`. Secret
files are mode 0600 and stay outside the checkout. Rerunning preserves the secret
and restarts the dedicated service. The unit is enabled for the user manager;
boot-without-login behavior is not promised and system-wide lingering is unchanged.
Stop it with `systemctl --user stop parlora-turn.service`; start it with
`systemctl --user start parlora-turn.service`. Logs are
available through `journalctl --user -u parlora-turn.service`. This UDP/TCP test
configuration disables TURN TLS and does not enable DTLS listeners; coturn may
warn about missing certificate files during startup. WebRTC media retains its
DTLS/SRTP encryption between the browser and Parlora through the relay.

## Consumer configuration

The host application owns these environment variables:

| Variable | Purpose |
| --- | --- |
| `PARLORA_STUN_URL` | Optional STUN URL, e.g. `stun:10.0.0.3:3478`. |
| `PARLORA_TURN_URL` | Optional TURN URL, tested with `turn:10.0.0.3:3478?transport=udp`. |
| `PARLORA_TURN_SECRET_FILE` | Private shared-secret file accessible to the host application. Required with TURN. |
| `PARLORA_ICE_POLICY` | `all` (default) permits direct or relay paths; `relay` requires TURN on both peers. |

`OrderDesk.BrowserICE` issues a new random username and a 600-second HMAC
credential for each request. The browser receives only these expiring credentials
through an Origin-checked, non-cacheable `POST /ice-config`; it never receives the
shared secret or the OpenAI key. The Elixir peer gets independently issued
credentials through `channel_options`. The development listener stays on loopback;
a deployed host must add application authentication to both credential issuance
and signaling. Keep host and TURN clocks synchronized. Longer host sessions would
need a deliberate credential-lifetime/refresh policy.

On the development Mac the test secret was transferred over SSH into
`~/.local/share/parlora-turn-client/auth-secret` (0600). It is separate from the
OpenAI Keychain credential. Restart the existing consumer listener, then run:

```sh
cd /Users/humberto/Projects/parlora_consumer
PARLORA_STUN_URL=stun:10.0.0.3:3478 \
PARLORA_TURN_URL='turn:10.0.0.3:3478?transport=udp' \
PARLORA_TURN_SECRET_FILE="$HOME/.local/share/parlora-turn-client/auth-secret" \
PARLORA_ICE_POLICY=relay scripts/browser.sh
```

Open http://localhost:4000 in Chrome. The page reports **TURN relay** and selected
browser/server candidate types. Change the policy to `all` for normal direct-first
ICE operation; omit all four variables to keep the original direct-only setup.
The browser reports ICE-server errors and a connection that closes before readiness.
The launcher uses info-level logging to avoid dependency debug traces containing
ICE credentials and private network details.

For a Linux consumer, use its `~/.local/share/parlora-turn/etc/auth-secret` and
an SSH HTTP/WebSocket forward as described in `docs/browser-channel.md`. The UDP
media uses coturn directly; it does not travel through the SSH forward.

## Automated checks

Run the consumer with the same TURN variables plus `PARLORA_BROWSER_OFFLINE=1`.
From `validation/browser` (after `npm ci`):

```sh
BROWSER_CHANNEL=chrome EXPECT_RELAY=1 npm test
# Disrupts only the dedicated parlora-turn service, then restores it:
PARLORA_TURN_FAILURE_TEST=1 BROWSER_CHANNEL=chrome \
  node turn_failure.cjs
```

Set `BROWSER_URL` to the consumer URL (the failure probe defaults to port 4002;
set it explicitly for port 4000). `TURN_SSH_HOST` defaults to `linux`. Run the
failure test without other TURN calls. It stops the service during a connected
call, verifies closure, starts the service again, and verifies explicit reconnect.
A `finally` block restores the service. Failed authentication in relay-only mode
must never reach readiness through a direct fallback. The standard browser test
also covers controls, repeated calls, permission denial, Origin rejection, page
closure and signaling loss. Selected candidate types and byte counters establish
relay use; setting a TURN URL alone does not.

A short live order-correction check can use `EXPECT_RELAY=1` with the existing
`PARLORA_BROWSER_LIVE=1 node live_order.cjs` harness and a live consumer. It uses
physical Mac audio and paid GPT-Live access, as documented in the browser harness.

## Boundary

These checks validate authenticated **TURN over UDP on the existing LAN**, with
Chrome on macOS and Parlora on macOS or Linux. TCP listener availability is not
proof of WebRTC TURN-over-TCP fallback. TURN TLS, public NAT traversal, firewall
fallback, hotspot access and browser/network switching are unverified. No public
ports, certificates or router mappings were added. A hotspot test requires a
publicly reachable relay or suitable network routing and is a separate step.

## Recorded results — September 16, 2026

[Numeric evidence](results.json) preserves the original observations. Mac STUN
Binding succeeded. Forced relay-only Chrome tests passed against both the macOS
and Linux consumer: three calls per server, both selected candidates `relay`,
nonzero bidirectional byte counters, no lost packets or concealed samples in
those short calls, and working mute/clear/suppression/resume. Wrong credentials
closed without readiness in 20,426 ms (Mac server) and 15,113 ms (Linux server).
Signaling loss closed in approximately 30 seconds. Graceful disconnect/page-close
cleanup took 8–32 ms and 7–26 ms respectively.

Stopping coturn during a connected call closed the session in 6,005 ms. No
automatic session replay occurred; an explicit reconnect succeeded after service
restart. No relay sockets remained after the tests and live call finished.

One physical Mac GPT-Live/Jido call through coturn lasted about 29 seconds. Both
selected candidates were relays; the current order 124 result was accepted, order
123 became stale, and a duplicate delegation was associated without another job.
The browser received 2,847 packets and sent 1,423, with zero packet loss or
concealment and positive decoded energy. The call also reported
185 capture drops and six source-starvation observations; these can occur during
startup and deliberate controls, and the counters do not
establish audible glitches or prove glitch-free playback. The scripted caller
used macOS `say` with deliberate output suppression during its utterances, so this
is not a human-listening or automatic barge-in evaluation.

Both platforms passed `mix ci` (105 tests; the three unrelated stability tests
remain separately tagged), including native checks, Credo/ex_slop, ex_dna,
Credence and Dialyzer. All five consumer tests passed on both platforms, covering credential issuance,
expiration encoding, endpoint Origin protection, non-caching and existing session
behavior. A further three-cycle direct-mode Chrome run also passed after the
configuration changes.
