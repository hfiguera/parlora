> Historical Extended Thinking audit. The user subsequently pivoted the Gemini provider to standard Live; see [current implementation and validation](standard-live/README.md). This audit is retained rather than reclassifying old results.

# Completion audit — 2026-09-24

Decision: **not complete; blocked on live asynchronous tool execution and the
qualification that depends on it.** This preserves the original full-alternative
objective. Passing local contracts is insufficient to achieve it.

The previous goal turn made progress: it corrected handle retention, verified
production-adapter resumption once, verified live PCM/PCMU conversion, and tested
real API interruption through the production session/pipelines. The same live
tool-dispatch blocker was present in the original goal turn, that continuation,
and the current continuation.

## Requirement-by-requirement evidence

| Requirement | Current authoritative evidence | Assessment |
| --- | --- | --- |
| Read saved Gemini docs and check ambiguous protocol details | `docs/gemini-3.8-live/`; current official Live API, thinking, model and session-management references linked in the guide; retained raw/SDK probes | Completed research; actual server limitations remain explicit |
| Secure key, environment and explicit library option | Both `with_keychain.py` launchers; runtime configs; `OrderDesk.Provider`; live authenticated runs; credential scans | Implemented and exercised; no key or resumption handle retained in evidence |
| 1. Gemini adapter, selected model, low/configurable thinking, audio, captions, readiness, bounds, errors, shutdown | `lib/parlora/providers/gemini*`; protocol/audio/adapter tests; live PCM/PCMU logs | Implemented; local lifecycle and live audio verified |
| 2. NON_BLOCKING calls into application policy/Jido, correlation, revisions, clarification, cancellation, deduplication, stale results | `Gemini.Calls`; session/decisions changes; provider-contract and OrderDesk tests; one passing live order lookup | Locally verified and live lookup demonstrated; full reliable task behavior contradicted by live failures |
| 3. Background state separate from utterance/backend/playback; receive after turnComplete | Protocol multi-event handling; provider/session activity; live raw tool call after utterance completion | Implemented and observed |
| 4. Interruption clears provider/pipeline/channel; late cancelled results cannot repeat/undo business actions | Loopback and provider-contract tests; `session-live-interruption-complete.log`: epoch 1, zero stale frames, fresh Hello audio, 567 ms input-to-clear | Clear path verified live with in-memory channel; provider-issued function cancellation remains unverified live |
| 5. Honest context semantics, greetings and browser-save announcements, preserve OpenAI ACK guarantees | Capability flag, unconfirmed delivery, unsupported quiet/instruction updates, context submission tests; targeted browser-save pass on both providers | Implemented and verified for covered behavior |
| 6. Browser/local PCM then Twilio/Telnyx mu-law conversion; captions and numbers without fabricated timestamps | G.711/resampling tests; `adapter-live-pcm.log`, `adapter-live-pcmu.log`; browser task pilot; untimed-number regression | Implementation and real-API conversion verified; no physical/PSTN quality qualification claimed |
| 7. Bounded resumption, GoAway, compression, usage, duplicate prevention and uncertainty | Handle-retention regression; two attempts with two-second delay; injected-GoAway live adapter success; sliding-window setup accepted; usage.json; continuity explicitly unverified | Implemented; narrow resumption success with inconsistent raw reference recall. No natural-GoAway or long-compression endurance proof |
| 8. OrderDesk selection and operational documentation | `OrderDesk.Provider`, runtime and launchers; `docs/gemini-provider.md`; README and evidence | Completed |
| Bounded initial pilot, then complete implementation | Retained raw probes and production implementation | Audio/calls demonstrated, but pilot cancellation did not qualify; it remains a limitation rather than an assumed pass |
| Meaningful protocol, provider-contract, lifecycle, audio, application tests | Latest macOS/Linux `mix ci` logs named in checks.json: 269 passed; OrderDesk 153 passed; matching current source hashes | Passed locally; does not prove live task parity |
| Realistic correction, interruption, late cancellation, clarification, follow-ups, browser saves and reconnect scenarios | Six-case task batch and targeted attempts; explicit late-cancellation tests and live interruption/recovery probes | Exercised; several Gemini scenarios stopped before their target stage because initial dispatch failed. Full live qualification incomplete |
| Compare correctness, latency, interruptions, audio continuity and usage with existing provider | comparison.json, usage.json, platform audio reports, raw and session-level live probes | Correctness gap measured (1/6 vs 6/6); caption/buffer timings and differing usage units reported. No acoustic-quality, billing or full interruption-parity claim |
| Required checks on macOS and Linux; inspect SSH environment | checks.json and linked platform reports; updated CI and release smoke logs | Passed for checked source; earlier setup/timing failures retained in report |
| Bounded live validation, keep credentials private, report limitations | Time-bounded scripts, no secret in arguments/files, evidence scans; provider guide and report | Completed within covered scope |
| Complete alternative to GPT-Live-1 | Repeated pre-dispatch failures in raw WebSocket, production adapter, OrderDesk, and Google SDK | **Not achieved** |

## Current blocker revalidation

`SDK-minimal-tool` uses Google's SDK, the requested Extended Thinking model,
LOW thinking, a no-argument NON_BLOCKING function and a synthetic command.
`sdk-minimal-tool-revalidation.json` again contains **zero tool calls**, a spoken
system-error response, and eventual IDLE. Its failure occurs before the fixture's
function-response code can run. The no-argument fixture's response was corrected
for future successful runs; it does not affect these pre-dispatch failures.

The observations reproduce outside Parlora and across both rich and minimal tool
schemas. They do not identify Google's internal cause or establish a global
outage. Further blind retries, changing business policy to execute without a
model call, fabricating acknowledgments, or silently switching models would not
satisfy the requested objective.

The next required change is reliable behavior from this model/API or a verified
protocol remedy identified through provider-side investigation. Once available,
rerun the existing bounded async-call/cancellation pilot, then the same OrderDesk
scenarios and comparisons without discarding earlier failures. The implementation
remains opt-in; OpenAI remains the default.

## User-requested HIGH and schema investigation

[Additional evidence](high-thinking-investigation.md) verifies the actual production
tool declarations against SDK serialization and exercises the highest documented
thinking level. Five HIGH sessions yielded zero correct task answers. Four failed
before any tool call; one minimal SDK case failed after its response. No declaration
format defect was found. This preserves the incomplete qualification assessment;
it does not prove the service's internal failure cause.

## Standard Live control

[The controlled model comparison](model-comparison/README.md) yielded 5/5 correct
fixture answers on standard Live and 1/5 on Extended Thinking HIGH. It narrows the
observed reliability difference to the model/service paths under shared client
conditions, without proving an internal cause. Standard Live has not been
implemented or qualified as a production Parlora provider. The Extended Thinking
qualification remains incomplete; no production configuration was changed.
