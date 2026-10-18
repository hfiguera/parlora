# Telnyx milestone completion audit — 2026-09-18

The objective is the incoming Telnyx channel plus the existing OrderDesk application,
not a standalone protocol probe. Evidence below is from the current implementation.

| Requirement | Implementation and evidence |
| --- | --- |
| Public channel with existing contracts | `lib/parlora/channels/telnyx.ex`; substitution test runs corrections with both fake backend and Jido; no provider/backend behaviour changes |
| Mountable HTTP/WebSocket helpers | `telnyx/endpoint.ex`; endpoint/signature tests and real Bandit/Mint socket test; live signed webhooks and authenticated upgrades |
| Voice API through Mint | `telnyx/commands.ex`, `http.ex`; stable-ID retry, timeout, response-size, 429/reset, rejection/redirect tests; real answer/streaming commands |
| Explicit raw PCMU 8 kHz mono RTP mode | Stream options test, exact byte socket test, live caller audio; own Telnyx protocol, not Twilio framing or full RTP packets |
| Supervision, finite bounds, readiness/pacing/reorder | Shared internal MediaStream runtime; Telnyx reorder/duplicate/gap tests, queue/format tests; channel settings and session Limits configurable; example gate uses documented fixed launch caps |
| Playback/clear/stop/resume | Unit clear-race/tail-padding checks plus `results/controls-pass/7-remote-controls.json`; old marks stay unknown; barrier then resumed result |
| Signature freshness and replay/admission | Raw Ed25519 tests, timestamp bounds, call/event state tests, gate admission; old hangup-before-initiation cannot resurrect a call |
| Separate expiring media credentials/identity | Per-call single-use gate tests including expiry and cross-call credential rejection; real socket rejects unauthenticated requests and binds format/call IDs |
| Async commands and uncertain outcomes | Blocked-worker responsiveness, late completion, drain tests; bounded supervised command tasks; HTTP acceptance distinguished from signed lifecycle and playback |
| Concurrent call isolation/cleanup | Gate credential/hangup isolation, separate channel audio/epoch test, socket owner death cleans session/provider/backend; live reconnect during running job |
| Existing application policy/TypeSafe/Jido/store/review | TelnyxServer uses BrowserGate and the same ContextPolicy/agent/store; live scenarios 4–6 verify refusal, exact UI confirmation, saved/pending state across reconnect |
| Safe credentials | Launcher child environment; explicit library options; 34 retained JSON/log artifacts scanned against the six runtime API/verification secrets with zero matches; no raw recordings |
| Account preflight/ngrok/routing | Read-only association/active-call checks; five route tests; each live run's cleanup JSON records restored_and_verified and temporary caller application deletion; final preflight found one number and zero active calls |
| Six acceptance cases | `results/suite-pass/suite.json`, with checkpoint/transcript/job/audio evidence in each numbered JSON; seven calls including reconnect |
| Preserve existing channels | Full CI covers LocalAudio, Browser, Twilio and Telnyx; shared internals retain separate vendor framing and Twilio owner tags/short tails |
| Standalone consumer synchronization | Byte comparison of all tracked fixture files against `/Users/humberto/Projects/parlora_consumer` found no differences; vendored library source refreshed from built package |
| macOS/Linux pinned checks | `results/macos-ci.log`, `linux-ci.log`: 164 passed, 3 existing exclusions; native, Credo/ExSlop, ExDNA, Credence, Dialyzer all pass |
| Fresh packages/production releases | Both `*-source-package.log` files: 84 tests, format and warnings-as-errors for application compile; release runs outside project without Mix, real native path and Jido, correct/stale jobs and finalized usage |
| Documentation/scope | Brief Milestone 6, public interfaces, README, implementation status, Telnyx guide, consumer setup and this evidence; no dependency/lock changes, outbound product feature/transfers/conferences deferred |

## Interpretation and remaining limitations

Scenario 4 preserves the current application policy: spoken refusal rejects an
identified pending draft. The same draft is no longer pending for a second UI
rejection. Scenario 5 separately proves UI rejection and exact confirmation.
Saved instructions remain unchanged on refusal and spoken approval does not save.
This is documented explicitly rather than changing application semantics for the
Telnyx channel or claiming a UI action happened when it did not.

The six-case run had six pre-readiness input-overflow observations and startup
buffer discards, zero post-readiness discontinuities, and no adapter failures.
REST hangup raced with caller disconnect (422); signed events confirmed all ended.
Synthetic calls do not verify human handset quality or every carrier/network.
Physical Linux sound devices remain unverified and are not used by this channel.
Memory-only routing restoration cannot survive process/host loss. External edits
are not overwritten; the API lacks atomic compare-and-swap. Upstream dependency
warnings in fresh builds remain visible; no checks were disabled to hide them.

Both failed live attempts remain under `results/`: observer struct-access crash
(fixed with regression test) and readiness-harness race (waits for actual ready).
The successful repeat and complete suite do not erase those failures.
