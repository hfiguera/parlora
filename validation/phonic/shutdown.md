# Phonic normal shutdown — 2026-10-29

A successful manual Twilio call ended at 03:37:16 UTC, but Phonic finalized its
conversation at 03:37:47 UTC with `ended_by: error`. The Phonic adapter closed
its underlying connection without a WebSocket close frame. Phonic retains
abnormal disconnects for approximately 30 seconds to permit reconnection.

An isolated live comparison reproduced the cause: the old adapter finalized as
`error` 30,229 ms after close; sending a normal WebSocket close finalized as
`user` after 29 ms. No OrderDesk policy, tool, or caller audio was needed.

## Change

Only Phonic's runtime changes. Explicit application close and normal process
termination send a masked WebSocket close frame with code 1000. The adapter
bounds the write and acknowledgment wait to 250 ms or the smaller configured
session shutdown budget, and discards tail frames without consuming unrelated
process messages. Repeated close requests remain idempotent. Before WebSocket
initialization, it performs transport cleanup without encoding a close frame.

Live validation exposed a second shutdown wait: OTP's default TLS close could
block for approximately five seconds after the WebSocket acknowledgment, causing
the public adapter close call to time out. Passing a timeout to `ssl:close/2`
alone did not resolve that wait on this runtime. Phonic now shuts down TLS in
both directions after the WebSocket exchange, then releases TLS state. The local
TLS regression deliberately acknowledges WebSocket close while delaying further
TLS processing.

Actual provider failures keep their existing abort and failure behavior. Other
provider adapters, the shared WebSocket helper, session coordination, TwiML,
OrderDesk policy, and JEV settings are unchanged. The local close event still
reports `finalized?: false`; cloud record finalization is checked independently.

## Reproduction and tests

From the repository root:

```sh
# Expected historical failure: six failures and two passes.
MIX_ENV=test mix run validation/phonic/replay_shutdown_before.exs

# Current implementation: eight shutdown regressions pass.
mix test test/phonic_shutdown_test.exs --warnings-as-errors

# Includes existing delegation, correction, interruption and codec cases.
mix test test/phonic_shutdown_test.exs test/phonic_adapter_test.exs \
  test/phonic_protocol_test.exs test/phonic_session_test.exs --warnings-as-errors
```

The raw socket fixture checks the masked close frame and its actual code, peer
acknowledgment, repeat calls, normal termination, a silent peer, the smaller
shutdown budget, discarded tail frames, retained unrelated messages, startup
cleanup, and genuine failure classification. Its TLS certificate is generated
locally for the fixture; it is not a service credential.

The focused suite passes **48 tests**. The full library suite passes **603
checks** (six properties and 597 tests; three hardware/live/stability cases
excluded). OrderDesk passes **248 tests** with the updated vendored library.

## Live service proof

Run the real adapter through its public close API, three times per supported
codec. This uses no caller audio, backend work, phone calls, or stored order
mutations. The API key is injected by the existing Keychain launcher:

```sh
PARLORA_PROVIDER=phonic \
ERL_FLAGS='+S 4 +sbwt none +sbwtdcpu none +sbwtdio none' \
  python3 examples/order_desk/scripts/with_keychain.py \
  mix run validation/phonic/shutdown_live.exs /tmp/phonic-shutdown.json

PARLORA_PROVIDER=phonic \
  python3 examples/order_desk/scripts/with_keychain.py \
  python3 validation/phonic/check_shutdown_live.py /tmp/phonic-shutdown.json \
  --output /tmp/phonic-shutdown-verified.json
```

The independent REST check waits for both `ended_at` and `ended_by`, requires
three PCM and three mu-law records, and rejects an incomplete set, an abnormal
classification, a delayed cloud ending, or a close call exceeding its normal
one-second admission timeout. Timestamp differences are wall-clock observations
and permit limited server/client clock skew.

A separate synthetic Twilio stream exercised the running OrderDesk phone server
through the public tunnel. It received greeting media, sent a Twilio stop event,
and verified Phonic ended as `user` after 113 ms. This tests the phone socket to
session to provider shutdown path; it does not claim a second human PSTN call.

See [compact evidence](shutdown-summary.json) for source hashes, before/after
records, intermediate validation failures, and evidence limits. These checks do
not establish remote finalization during an actual network outage or broad
production readiness.
