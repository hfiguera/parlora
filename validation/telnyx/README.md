# Telnyx milestone validation

See [the implementation tracker](../../docs/telnyx-channel.md) for the contract,
setup, finite limits, measured outcomes and remaining limitations.

## Automated checks

- Full library `mix ci`: 164 passed, three existing exclusions, all native and
  quality checks pass on macOS and Linux. Logs are under `results/`.
- Fresh source-package consumers: 84 tests pass on each platform; format/compile
  and production release scenarios pass.
- Five Telnyx and four Twilio offline routing tests pass.
- Real Telnyx smoke, six acceptance scenarios and remote-control scenario pass.
- `results/summary.json` aggregates calls, queue peaks, discontinuities and cleanup.
  Individual case JSON retains the supporting observations; failed attempts remain.
- `foundation-macos-ci.log` preserves the earlier foundational run.

## Live-network harness

From the Parlora root, with the synchronized standalone consumer available:

```sh
ORDER_DESK_TELNYX=1 ORDER_DESK_TWILIO=1 ORDER_DESK_TYPESAFE=1 PARLORA_ACCEPTANCE_LIVE=1 \
  python3 examples/order_desk/scripts/with_keychain.py \
  python3 validation/telnyx/live.py /tmp/parlora-telnyx-UNIQUE
```

Append `--suite` for the six acceptance cases, or `--controls` for clear/suppress/
resume. The script starts ngrok and separate private/public listeners, uses a
fixed-destination Twilio SDK caller to the saved Telnyx number, installs a temporary
Telnyx webhook, and restores it afterward. It deletes its temporary Twilio caller
application and ends only its own test legs. No number routing changes are made
on Twilio. Secrets travel through environment/stdin and stay out of evidence.
Synthetic audio and an isolated SQLite database are placed in the output directory.

This exercises the real Telnyx network/media path with synthetic speech. It does
not establish human handset quality. Do not enable browser tracing or ngrok
request inspection because stream tokens and credentials must remain private.

## Preserved failure

`/tmp/parlora-telnyx-live-smoke-20260918a` contains the first live check. The call
connected and returned audio, but `PhoneDiagnostics` crashed when it accessed a
backend-result struct using the Access behaviour. A regression test covers the
Map.get fix. Both caller legs completed (24 seconds), and `cleanup.json` confirms
original routing restored and the temporary caller application deleted. This run
is a failure, not an acceptance pass.

No dependency changes were needed.

## Evidence interpretation

The six-case suite used seven calls, including reconnect. All sessions closed,
no after-readiness discontinuities or adapter failures were recorded, and command
workers/queues/unconfirmed calls ended at zero. Pre-readiness input overflow and
startup discard remain explicit in the summary. Controls kept old clear marks
unknown and verified suppression/resume at the caller. All routing leases restored.

Scenario 4 follows the current application policy: spoken refusal rejects an
identified pending draft without changing saved data. There is then no pending
draft to reject a second time in the UI. Scenario 5 exercises explicit browser
rejection of the obsolete draft and confirmation of only the corrected draft.
The Telnyx adapter does not reinterpret or duplicate this business logic.
