# Grok Voice 3.0 migration — October 17, 2026

The maintained Grok adapter, examples and active validation runners now select
`grok-voice-3.0`. Reasoning remains `high` by default. Explicit `none` support is
preserved, but this migration's paid probes all select HIGH. Audio limits,
playout policy, delegation ownership and business permissions are unchanged.

## Verify the model actually selected

The authenticated [availability investigation](model-availability.json) found
that `/v1/models` omitted all voice models, including the documented Voice 3.0.
The WebSocket endpoint accepted both the speculative Think Fast 3.0 name and a
deliberately invalid name, while reporting `grok-voice-3.0`. A successful
connection alone cannot establish that a requested identifier exists.

The production adapter now requires `session.updated` to report the pinned model
and the requested reasoning effort before announcing readiness, sending input
audio or replaying user/assistant history. Missing, malformed or different configuration
fails startup with `configuration_mismatch`. Regression tests cover substitution,
missing evidence, mismatched reasoning, malformed fields and explicit NONE.

## Retained live attempts

The protocol pilot records the actual acknowledged model and reasoning as
separate checks. Every report below uses synthetic Samantha speech and contains
no credentials or raw audio. These are separate attempts, not replacement retries.

- [Rapid pending-work follow-up](pending-pcm.json): the lookup and delayed result
  succeeded, but the question spoken one second after the tool call produced no
  second speech-start or caller transcript and was not answered. This remains a
  failed attempt. The wire probe bypasses Parlora's adapter and playback; it does
  not establish the provider's internal cause or prove a model-version regression.
- [Settled pending-work follow-up](pending-pcm-settled.json): with a three-second
  gap, the model answered Paris while the lookup remained pending, then announced
  the verified Friday result. This establishes a successful timing configuration,
  not a fix for the rapid-input failure.
- [Correction](correction-pcm.json): the replacement lookup arrived before result
  submission; only order 124's current result was announced.
- [Interruption](interruption-pcm.json): interrupted generated counting and
  produced the requested new answer.
- [Independent work](independent-pcm.json): separate evidence for a second lookup
  completing while the first remains pending.

The earlier adapter's [qualification report](../README.md) also retains missed
rapid-input attempts. Those historical observations are not a controlled
Voice 2.0 versus 3.0 comparison and are not relabelled as Voice 3.0 evidence.

The production-adapter and release-check summaries are in
[verification.json](verification.json); the source hashes identify this working
tree rather than assuming the parent commit contains the migration.

| Check | Result |
| --- | --- |
| Full library `mix ci` | 430 checks passed (6 properties and 424 tests), 3 hardware/live/stability exclusions; native tests, format, Credo, ExDNA, Credence and Dialyzer passed |
| Standalone Jido consumer | 222 tests passed; source package, production release and offline smoke passed |
| Development compilation | Warnings-as-errors compilation and formatting passed |
| Node runner/evaluator regressions | 23 tests passed |
| [Offline browser release](release-offline.json) | All 4 steps passed; 3 recovery scenarios passed; zero active sessions after cleanup |
| [Production PCM adapter](adapter-pcm.json) | One lookup, delayed result, transcript and generated audio passed |
| [Production PCMU adapter](adapter-pcmu.json) | Same lookup/result flow passed at 8 kHz |
| [Production session interruption](pipeline-interruption.json) | Epoch advanced; fresh audio resumed; zero stale frames after clear |
| [Initial WebRTC batch](webrtc-initial.json) | 5 passed, 2 failed; failures retained below |
| [WebRTC with observed greeting drain](webrtc-drained-greeting.json) | All 7 passed; zero active sessions after cleanup |

The first CI invocation also exposed two pre-existing Credence findings in playback
test helpers. The cleanup fuses a map/sum and directly returns a final reduce;
the test assertions and production playback code are unchanged. The final full
CI invocation passes, rather than bypassing those checks.

## Browser task qualification

The first seven-case synthetic WebRTC/Jido batch used the existing caption-based
greeting wait and passed five cases. Its two failures remain separate evidence:

- [Items request](initial-05-items-124-r1.json): no caller transcript or backend
  job appeared. The request began while greeting source audio was still draining.
- [Spoken approval](initial-19-spoken-approval-r1.json): the saved records were
  unchanged and the draft stayed pending. The model said saving had to happen on
  the page, but omitted the concrete Confirm action required by the evaluator.

The task harness now waits for provider generation to become idle and for source
forwarding to remain quiet for 500 ms before ordinary task input. This changes
test synchronization only; the library's 120 ms startup target, adaptive buffering
and interruption handling are unchanged. Node regressions verify that generation
idle or an absent greeting alone cannot satisfy the gate. The distinct
post-change seven-case batch is recorded in `verification.json`; the original
failures are not removed or pooled into a passing rate. A later passing approval
response does not prove the earlier wording failure has been eliminated.

## Reproduction

Use the pinned toolchains and `websockets==15.0.1`, macOS `say`, and ffmpeg.
The launchers obtain existing credentials privately; never pass keys in argv.

```sh
mix ci
node --test validation/release/*_test.cjs validation/task-pilot/*_test.cjs validation/acceptance/*_test.cjs
scripts/consumer.sh /absolute/new-consumer
PARLORA_PROVIDER=grok GROK_REASONING_EFFORT=high BROWSER_CHANNEL=chromium \
  scripts/release_check.sh /absolute/new-consumer --output /absolute/new-offline-report
python scripts/grok_protocol_pilot.py --scenario pending --reasoning high --output /absolute/new-rapid-report.json
python scripts/grok_protocol_pilot.py --scenario pending --reasoning high --followup-delay 3 --backend-delay 16 --output /absolute/new-settled-report.json
python scripts/grok_protocol_pilot.py --scenario correction --reasoning high --followup-delay 3 --output /absolute/new-correction-report.json
python scripts/grok_protocol_pilot.py --scenario interruption --reasoning high --output /absolute/new-interruption-report.json
python scripts/grok_protocol_pilot.py --scenario independent --reasoning high --followup-delay 3 --backend-delay 25 --output /absolute/new-independent-report.json
PARLORA_PROVIDER=grok PARLORA_BACKEND=jido GROK_REASONING_EFFORT=high BROWSER_CHANNEL=chromium \
  node validation/task-pilot/run.cjs /absolute/new-consumer /absolute/new-live-report \
  --live --repetitions 1 --cases 01-cardinal-124,05-items-124,12-correction,14-followup-items,19-spoken-approval,20-browser-confirmation,21-reconnect
```

Read the [current upstream protocol](https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech)
and [release notes](https://docs.x.ai/developers/release-notes) for the documented
wire compatibility. This migration does not qualify human listening, accents,
noise, actual Twilio/Telnyx phone calls or long-session production reliability.
Model response completion and provider captions do not prove physical playback.
