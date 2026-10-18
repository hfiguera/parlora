# Grok implementation qualification audit

Date: 2026-10-03. Model: `grok-voice-think-fast-2.0`.
Implementation commit: `1fcb2adfbc39f4a5b6ed5190f950fa55f4558b74`.

The adapter is implemented and qualified for the bounded automated cases below.
This audit is not human conversation qualification or a production reliability
claim. HIGH and NONE are recorded separately. Business interpretation remains
application-owned through ContextPolicy/Jido and OrderDesk's TypeSafe interpreter.

| Requirement | Implementation and evidence |
| --- | --- |
| Continue conversation during slow backend work | HIGH/PCM and NONE/PCMU pending-work probes answered an unrelated question before the original result, then announced the result. |
| Independent backend tasks | `protocol-independent-high-pcm-delay25.json` announced the fast order 124 result while order 123 remained pending, then the original result. Loopback tests distinguish independent response groups from parallel calls within one response. |
| Correction and superseded work | Three-second-gap HIGH/PCM and NONE/PCMU probes superseded order 123 without submitting its obsolete facts. Final OrderDesk slow-correction case passed with application-owned task revision handling. Duplicate/conflicting IDs and late superseded results are tested separately. |
| Application-owned writes | Browser confirmation and independent browser save announcement passed with exact saved text and existing authorization. Provider functions only delegate bounded requests; no provider-managed business execution. |
| Interruption and stale output | Protocol interruption passed; production Session memory-channel evidence records one clear epoch, zero stale frames after clear, and fresh output. Adapter tests cover matching tokens, old response IDs, and expired barriers. Physical speaker output was not measured. |
| Readiness and transport | Loopback Mint WebSocket tests require configuration acknowledgment, redact diagnostics, fail startup/continuation deadlines, and release resources on closure. No transparent reconnection/replay is claimed. |
| Bounds and correlation | Finite input/output queues, transcript/call/command records, retained audio age, local mute, paced large frames, duplicate commands, uncertain sends, and response-group continuation are tested. Overflow and stale reads explicitly fail and close. |
| Transcripts and optional capabilities | Cumulative caller candidates finalize once after commitment. No fabricated timestamps, usage, context acknowledgment, or playback completion. Only speakable context is supported after setup. |
| Codecs and reasoning | Production adapter probes passed PCM16LE/24 kHz with HIGH and PCMU/8 kHz with NONE. Setup tests cover both codecs and explicit HIGH/NONE; release-plan tests separate their comparison keys. |
| Application integration | Canonical OrderDesk, local voice, Keychain launchers, runtime configuration, task pilot and release plans select Grok. Existing channels are used; provider-managed SIP is excluded. |
| Existing providers | Root CI includes existing OpenAI/Gemini regression coverage. Shared Mint connection and audio helpers retain Gemini's existing 10-second burst profile; Grok uses a separate finite 20-second profile. |

## Final checks

- Root `mix ci`: 306 passed (6 properties, 300 tests), 3 excluded; native Rust
  tests, formatting, Credo/ExSlop, ExDNA, Credence and Dialyzer passed.
- Development compile with warnings as errors passed.
- Canonical consumer: test compilation with warnings as errors, formatting, all
  194 tests, production compilation and production release assembly passed.
- Production release smoke: Grok module/configuration available, HIGH explicit,
  PCM burst limit 960,000 bytes, Mix absent, native audio/stale-result smoke passed.
- Offline release: evaluator tests, acceptance, browser recovery (three cases,
  zero remaining sessions), and interpretation diagnostics passed. The fixed
  7-case × 3-attempt paid release batch was not run; bounded live batches are
  recorded separately.
- Python harness/launcher syntax and Git whitespace checks passed.

Logs are under `checks/`; offline plan/report are under `release-offline/`.
`checks/source-audit.json` records SHA-256 of the final implementation, relevant
configuration, tests and harnesses and verifies consumer source parity. Live
reports retain the checkout's prior Git HEAD plus dirty status, not a retrospectively
assigned final commit. Their recorded harness hashes and separate batch directories
identify attempts; do not assume every earlier attempt used the final adapter.

## Preserved failures and changes

Two one-second-gap correction probes produced no second speech-start/caption;
three-second-gap attempts passed. The internal cause remains unestablished.
The first independent-work diagnostic used an ambiguous follow-up and insufficient
separation of result timings; its failure remains recorded.

OrderDesk's initial six-case batch passed. A second six-case batch had one
`output_overflow` during draft confirmation with the 10-second profile. Grok's
finite capacity was increased to 20 seconds with a 21-second residence limit;
both save cases then passed. The final response-group implementation separately
passed correction and both save cases (three cases, one attempt each). These are
not pooled success rates or retries replacing failures.

A final consumer run had a scheduler-sensitive negative assertion in the existing
save-announcement pause test. Its isolated rerun passed. The test now advances
pause state and ticks explicitly, preserving the source-audio guard and checking
that silence packets do not postpone delivery. The final full consumer suite passed.
Both the failed log and rerun are retained.

Remaining qualification: human microphones/listening, accents, noise, physical
playback, PSTN interoperability, extended sessions and statistically meaningful
reliability. No provider-managed SIP, usage billing totals, quiet updates,
post-setup instruction changes or provider context acknowledgments are claimed.
