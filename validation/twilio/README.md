# Twilio milestone validation

The incoming-call milestone is implemented; see [the channel guide](../../docs/twilio-channel.md).
Do not replace failed evidence with subsequent passing reports.

## Live provider format probe

`live_format.exs` runs the actual OpenAI adapter with μ-law audio and a simulated
channel/backend. It drains playback without opening speakers, sends a greeting
instruction after readiness, observes for at most 12 seconds, and awaits close
for at most seven seconds. It uses no Twilio number and changes no routing.

From the library repository on the development Mac:

```sh
MIX_ENV=test ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 /Users/humberto/Projects/parlora_consumer/scripts/with_keychain.py \
  mix run validation/twilio/live_format.exs
```

On another environment, provide `OPENAI_API_KEY` through runtime environment
configuration and invoke `MIX_ENV=test mix run validation/twilio/live_format.exs`.
No credential values are written to evidence files.

- `live-format-first.json`: original unsuccessful probe and diagnosed harness bug.
- `live-format-diagnostic.log`: instrumented failure before readiness.
- `live-format-after-harness-fix.log`: provider accepted μ-law, generated audio,
  and finalized. No Twilio or human playback claim follows from this result.

## Final milestone results — September 18, 2026

The incoming-call milestone is complete. [Machine-readable results](results.json)
and [channel semantics/measurements](../../docs/twilio-channel.md) describe the
validated scope and limitations. No package was published.

| Check | macOS | Linux (`ssh linux`) |
| --- | --- | --- |
| Library `mix ci` | 144 passed, 3 explicitly excluded | 144 passed, 3 explicitly excluded |
| Native checks, Credo/ExSlop, ExDNA, Credence, Dialyzer | Passed | Passed |
| Standalone consumer against fresh source package | 63 passed | 63 passed |
| Production release, without Mix at runtime | Passed | Passed |
| Six live application scenarios | 6/6, controlled SDK caller | Not repeated against Linux hosting |
| Live remote clear/suppress/resume | Passed | Not repeated against Linux hosting |

Both platforms use Elixir 1.20.4 / Erlang 29.0.6 and the repository's pinned
native toolchain. The library's excluded tests explicitly require physical/live/
long stability runs; they were not changed to obtain a pass. The current Twilio
live checks use separate fixtures. No production Mix dependency changed; the
controlled caller's Voice SDK 2.18.3 has its own npm lockfile.

The final release smoke verifies `Mix` is absent, loads Twilio and the phone
opening helper, exercises existing native/simulated session composition, and
confirms current order 124, stale-result rejection, provider acknowledgment and
finalized cleanup. It is separate from the real telephony acceptance evidence.
Release output: `/tmp/parlora-twilio-final-release-20260918` on both hosts.

### Reproduce deterministic checks

From Parlora, use the documented pinned environment and run `mix ci`.
From the standalone consumer, run `mix test` after refreshing `vendor/parlora`
from `mix hex.build --unpack --output YOUR_NEW_TEMP_DIRECTORY`.
The development Mac additionally selects
`RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin` and
`ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none'`.
Linux's existing validation environment is loaded from
`/tmp/parlora-browser-linux-env.sh`; its library checkout is
`/tmp/parlora-v1-20260915` and consumer is `/tmp/parlora-browser-package-audit`.

```sh
python3 -m unittest discover -s examples/order_desk/scripts -p test_twilio_route.py
node --check validation/twilio/caller.cjs
node --check validation/twilio/sdk.cjs
node --check validation/twilio/suite.cjs
```

Final detailed check logs are `/tmp/parlora-twilio-macos-final-ci.log`,
`/tmp/parlora-twilio-consumer-macos-final.log` and
`/tmp/parlora-twilio-release-macos-final.log`; corresponding Linux files replace
`macos` with `linux`. All checks exit successfully.

### Reproduce bounded live validation

Use the development Mac and the standalone consumer described above. The
harness requires the existing browser-validation Playwright installation and
Chrome, `ngrok`, `/usr/bin/say`, and the authorized development Keychain entries.
Install the isolated caller SDK with `npm ci --prefix validation/twilio`.
It creates an isolated database and synthetic speech assets under a new output
directory. It refuses to reuse a running ngrok agent on port 4040.

```sh
PARLORA_ACCEPTANCE_LIVE=1 ORDER_DESK_TWILIO=1 ORDER_DESK_TYPESAFE=1 \
  python3 examples/order_desk/scripts/with_keychain.py \
  python3 validation/twilio/live.py /tmp/parlora-phone-NEW-RUN --suite
```

Use `--controls` for the explicit remote-control case, or omit it for one bounded
status-lookup smoke. The caller dials only the configured development number
through a temporary TwiML application. It injects synthetic speech instead of
opening a physical microphone, and retains numeric received-audio measurements
without recording remote speech. Tokens reach the caller through stdin and stay
in memory; the public server exposes neither tokens nor the review API. Ngrok
request inspection is disabled. The private validation observer/control routes
are not shipped in the normal consumer listener.

Each scenario has a two-minute deadline and waits are individually bounded.
The controller limits the suite to 840 seconds; SDK grants expire after 900
seconds and each test Dial leg has a 120-second limit. The suite stops on its
first failure, preserves its evidence and exits unsuccessfully. Normal completion,
exceptions and graceful interruption run routing restoration and resource
cleanup; force-kill/host-failure limitations remain explicit. Prior URLs and
credentials are never saved to disk. Confirm `cleanup.json` before considering
temporary phone routing restored.

### Preserved failures and successful evidence

- `evidence/smoke-01`: SDK bundle import failed before dialing; fixed the package
  export-path mistake after a local reproduction.
- `evidence/smoke-02` and `handshake-diagnostic`: Twilio reached the number but
  received HTTP 403 on the stream upgrade. Only the exact WSS signature matched.
- `evidence/smoke-wss-fix`: real audio connected, then bounded playback expired.
  Its complete event report is gzip-compressed. Measurements showed 10 ms packets
  handed off every 11.8 ms, with marks advancing around 20 ms. Packetization and
  accumulated-deadline scheduling addressed the observed mismatch.
- `evidence/smoke-pacing-fix`: the application reached a real backend result, then
  the validation observer crashed because it used Access syntax on a struct.
  The observer now uses `Map.get`; this run does not count as a pass.
- `evidence/smoke-observer-fix`: full real order lookup, caller-side audio,
  open call, finalized close and restored routing.
- `evidence/suite-01`: the partial-number bug created extra correction jobs.
  Consumer regression tests cover bare spoken/numeric prefixes and clarification.
- `evidence/suite-number-fix`: no greeting was generated, so no scenario ran.
  The phone application now uses the documented instruction/acknowledgment/
  commentary sequence; deterministic tests reject unmatched acknowledgments and
  prevent redundant prompting after speech or rejection.
- `evidence/suite-opening-fix`: all six scenarios passed across seven calls.
  Every session emitted finalized closure, with provider usage of 10–26 seconds.
- `evidence/controls-01`: real remote clear barrier, ambiguous marks, local
  suppression, resume, a fresh accepted result and caller-side audio passed.

Every completed live run restored routing and deleted its temporary application.
The final account audit found the development number idle and zero remaining
`parlora-probe-` applications. Test browser/app/tunnel processes were stopped;
unrelated development services were not stopped.

## Requirement audit

| Requirement | Implementation and evidence |
| --- | --- |
| Existing public channel contract and media ownership | Twilio channel/Socket; fake/Jido substitution scenarios and live SDK → Twilio → Parlora → GPT-Live path |
| Raw μ-law format, duration, silence and byte budgets | AudioFormat/AudioFrame/Limits/provider audit; format/packetizer/pacer tests; actual provider and phone probes |
| Signed, mountable bounded endpoints | Endpoint/Signature; official signature vector, invalid-signature rejection, real WSS match, single-use call tickets, private review listener |
| Queue age, pacing, backpressure and remote evidence | 20 ms packetizer, finite local/inflight budgets and mark timeout; odd-byte tests; measured live peaks; no weakened limits |
| Clear races, interruption and resume | Playback unit tests, explicit live controls, and interruption during observed caller-side assistant audio |
| Malformed events, duplicates, ordering and unsupported formats | Protocol tests, real Bandit/Mint malformed-stream teardown and unsupported handshake assertions |
| Provider/transport failure and resource cleanup | Network failure tests, owner monitoring, close handshake, finalized live sessions; remote call termination stays distinct from stream closure |
| Multiple-call isolation | Two simultaneous signed sockets with distinct identities/audio; hangup leaves the other session operational; fresh live call has no inherited work |
| Business logic and save authorization remain in the application | Existing TypeSafe ContextPolicy/Jido/SQLite; six live scenarios; explicit private-UI save and spoken-refusal regression coverage |
| Standalone packaging and release | Fresh Hex source package consumed on both platforms; 63 consumer tests and releases without Mix |
| Finite configuration and measured defaults | Channel guide/defaults, queue peaks and mark latency; tiny impossible packet budgets rejected |
| Credential handling and temporary routing | Keychain-to-child environment, explicit library options; four restoration unit tests, real restoration reports and final read-only cleanup audit |
| Preserved scope and honest limitations | No Telnyx/general outbound/transfers/conferences/recording feature, no publication; human handset, carrier diversity, production endurance and physical Linux audio remain unverified |
