> Current provider: standard `gemini-3.8-live`. See the [pivot and qualification report](standard-live/README.md). Earlier sections below retain historical Extended Thinking evidence.

# Gemini Live implementation and qualification — 2026-09-24

**Implemented as an opt-in provider; not qualified to replace GPT-Live-1.**
The local adapter, session and OrderDesk contracts pass deterministic checks, but
live tool dispatch and resumption failed repeatedly. OpenAI remains the default.
See [configuration and operational semantics](../../docs/gemini-provider.md).

## What was implemented and verified locally

- Mint WebSocket setup/readiness, binary JSON frames, continuous 16 kHz input,
  PCM24 output, captions without invented timestamps, independent background state.
- Bounded input/output and record retention; long input frames split across ticks;
  mute clears queued speech while continuing silence.
- Correlated NON_BLOCKING calls through existing ContextPolicy/Jido, retained
  cancellation, task revisions, stale-result exclusion and duplicate protection.
- Coordinated provider/pipeline/channel interruption clearing, with new audio held
  until the matching clear barrier. No business rollback is inferred.
- Explicit unconfirmed context submission; no invented provider acknowledgments,
  quiet updates, mutable system instructions, or function scheduling.
- PCM24 and PCMU8 conversion, safe-boundary resumption attempts, GoAway deadlines,
  sliding-window compression configuration, and raw per-report token usage.
- OrderDesk selection, secure environment/Keychain launchers, greeting fallback,
  and browser-save announcements that distinguish submission from acknowledgment.

`mix ci` passed on macOS arm64 and Linux x86_64: **269 tests/properties**, native
checks, strict Credo/ExSlop, zero-clone ExDNA, Credence and Dialyzer. Standalone
OrderDesk passed **153 tests** and a production release smoke check on both hosts.
The three stability tests passed on both. Platform audio gates (200 matrix cases
plus browser receiver scenarios), offline acceptance/recovery, concurrency and
browser UI checks were also exercised. Final check summaries are in
[checks.json](checks.json).

The Linux host was inspected and used through `ssh linux`; it has Elixir
1.20.4/OTP 29.0.6 and Rust 1.92.0, with the existing native media environment.
No Gemini credentials were written to the Linux machine. Live tests ran on macOS.

## Live OrderDesk comparison

The same six synthetic-speech cases ran once per provider through Chromium,
WebRTC, the application policy, TypeSafe interpretation, real Jido and isolated
SQLite fixtures. Lookup 123 takes four seconds; lookup 124 takes one second.
The expected database effects and factual assistant captions are checked.

| Scenario | Gemini, low | GPT-Live-1 |
| --- | --- | --- |
| Lookup 124 | Pass | Pass |
| Ask for missing number, then lookup | Fail before backend dispatch | Pass |
| Correct 123 to 124 during slow lookup | Fail before first lookup; correction stage not reached | Pass |
| Follow up with items | Fail before initial lookup | Pass |
| Voice draft followed by browser confirmation | Fail before draft creation | Pass |
| Disconnect/reconnect then fresh lookup | Fail before initial lookup; reconnect stage not reached | Pass |

**1/6 versus 6/6 is the observed small batch, not a production success-rate
estimate.** All five Gemini failures had zero backend jobs and a spoken system
error. Thus they do not demonstrate bugs in Jido execution or database validation,
and do not establish that Gemini's later correction/reconnect behavior works.

The successful lookup's first assistant caption after input finished arrived at
1,397 ms for Gemini and 1,263 ms for GPT-Live-1. These are caption arrival times,
not first-audio or perceived latency. The [comparison data](comparison.json)
retains task durations, failures, job counts and reply-check timing. No acoustic
quality or interruption parity is claimed from this batch.

A separate targeted batch retained two further Gemini dispatch failures (lookup
and correction). A browser-created, browser-confirmed save **passed on both
providers**. It reaches the announcement path independently of tool dispatch.
GPT-Live-1's repeated lookup also passed. Targeted results remain separate from
the first batch, under `evidence/*-targeted/`; retries never replace failures.

[Usage observations](usage.json) preserve Gemini's token reports and OpenAI's
seconds reports. They have different units and are not final bills. Do not sum
Gemini per-message reports or present a cost comparison from this evidence.
The first batch did not capture usage; the targeted batch added explicit capture.

## Protocol evidence and service boundary

The exploratory `protocol-*.json` files retain successes and failures, including
configuration variants. Early probes predate the final reproducible script and
must not be treated as a controlled statistical sample.

- Automatic VAD with a short stream ending after speech often produced nothing.
  Continuous silence after speech enabled captions, audio and asynchronous calls.
  Production input therefore continues every 20 ms, including while muted.
- `protocol-stream-audio.json` demonstrates a low-thinking function call after the
  utterance-complete event, then a correlated response and later IDLE. Both text
  and binary WebSocket JSON must be accepted; the adapter tests use binary frames.
- Function dispatch sometimes succeeded and often returned spoken “system error”
  without a `toolCall`. Medium thinking and a different function name did not
  consistently fix it. `sdk-tool-low.json` reproduces this behavior using Google's
  `google-genai` 2.25.0 SDK, outside Parlora. This isolates the symptom beyond our
  Elixir adapter; it does not prove Google's internal root cause.
- `protocol-speech-cancel.json` received a call for 124, then correctly transcribed
  “cancel that lookup…123 instead” and spoke an acknowledgment. Neither a
  cancellation nor a replacement function call arrived before 45 seconds. The
  original result was intentionally withheld in this diagnostic. Late cancelled
  results and corrected revisions are covered locally; live cancellation remains
  unverified.
- Both live idle-resumption probes received an idle resumable handle, then failed
  reopening the session. `protocol-resumption-detail.json` records code 1011,
  “Internal error encountered.” Handles were never logged. The local adapter
  fails closed on this condition; transparent live recovery is not established.

No live PSTN call, physical speaker assessment, natural production GoAway, or
long-session compression test was completed. Follow-up API interruption evidence
is recorded below. PCM/PCMU conversion and channel clearing are locally tested; that
is not evidence of telephone or human-conversation parity.

## Reproduce bounded probes

Install `websockets==15.0.1` and, for the comparison only, `google-genai==2.25.0`
in a temporary Python environment. The Python probes retrieve the existing
Keychain item privately if `GEMINI_API_KEY` is absent. Never put a key in arguments.

```sh
python scripts/gemini_protocol_pilot.py --scenario audio --audio /absolute/mono16k.wav
python scripts/gemini_sdk_pilot.py
python scripts/gemini_resumption_pilot.py
PARLORA_PROVIDER=gemini python3 scripts/with_keychain.py mix run scripts/gemini_live.exs /absolute/mono24k.pcm
PARLORA_PROVIDER=gemini node validation/task-pilot/run.cjs /absolute/consumer /absolute/new-output --live --repetitions 1 --cases 01-cardinal-124,12-correction,22-browser-save-announcement
```

Raw protocols have a 45-second bound (50 seconds for resumption); the Elixir
adapter smoke test has 55 seconds; application cases have 75 seconds. The final
scripts exit unsuccessfully when their expected behavior is missing. Synthetic
speech is explicitly labeled and does not establish human/accent coverage.

The checked-in evidence includes synthetic transcripts and opaque call/session
IDs, but no keys, raw audio, or resumption handles. Large audio, build logs and
working consumer installations remain in the task's `/tmp/parlora-gemini-*`
validation directories. `evidence/*/plan.json` records harness/application hashes;
these exploratory runs used a dirty implementation checkout, not a released
provider build. Do not infer bit-for-bit historical provider provenance from HEAD.

The next qualification gate is a reliable live async-call/correction/resumption
run against this exact model. Until the failures are resolved, use Gemini for
controlled development and keep GPT-Live-1 for the validated application path.


## Follow-up: handle retention, reconnect delay, and live PCMU

The continuation found and fixed an adapter-side resumption bug. Gemini's live
responses can provide a resumable handle only once near setup. Clearing that flag
locally after every caption/function response prevented later safe resumption.
The adapter now retains the server flag and uses independent IDLE/pending-call
checks. The loopback regression test starts with the handle before a complete tool
turn, then verifies that it can resume without losing call tombstones.

Two-second delayed raw reconnects both completed setup: one recalled 124, and one
said it lacked that information. Thus a reconnect delay improved the observed
transport outcome, but does not prove its internal cause or reliable context
continuity. The production adapter now delays each of its at most two reconnects.
Its `provider_connection` resumed event explicitly carries setup evidence and
`continuity: :unverified`.

`adapter-live-resumption-fixed.log` demonstrates the real production adapter
reconnecting with an actual API handle and correctly recalling 124. The harness
injected a GoAway deadline at a safe idle boundary; it did not wait for a natural
server GoAway. The initial turn also produced a spoken system error after a long
background interval, so this is a narrow recovery success, not a clean end-to-end
conversation qualification. The preceding uncorrected adapter timeout is retained.

`adapter-live-pcm.log` and `adapter-live-pcmu.log` both correctly captioned the
synthetic “Hello, can you hear me clearly?” input and received response audio.
The PCMU run decoded input at 8 kHz, resampled to Gemini input, and encoded returned
audio to mu-law through the production adapter (26,639 output bytes observed).
This establishes real-API conversion interoperability, not physical/PSTN quality.

`google-genai` with a minimal no-argument NON_BLOCKING `turn_on_the_lights`
declaration still returned spoken system error before emitting a tool call
(`sdk-minimal-tool.json`). That rules out the particular order/request argument
schema as a sufficient explanation. The full replacement goal remains blocked
on reliable live asynchronous work, cancellation, and remaining qualification.

Reproduce the added probes with `scripts/gemini_sdk_pilot.py --minimal-tool`,
`scripts/gemini_resumption_pilot.py --reconnect-delay 2`, or the Elixir smoke
script with an appropriate raw input file and `--pcmu --conversation` or
`--resumption`. All retain their existing time bounds.


## Follow-up: interruption through the production session and pipelines

`session-live-interruption-complete.log` passes a bounded real Gemini test through
`Parlora.Session` and both production audio pipelines, using an in-memory channel
and no business work. During generated speech, synthetic input said “Stop. Just
say hello.” Gemini emitted an interruption, the channel advanced to playback
epoch 1, and the new response was “Hello.” The probe observed 31,696 bytes of fresh
audio and **zero stale frames after channel clear**. Input start to clear was
567 ms; this measures local buffer clearing, not sound already played or human
perceived latency. It is one probe, not an interruption success-rate estimate.

The preceding `session-live-interruption.log` ended too early: interruption
produced IDLE while the new input was still arriving. The corrected harness keeps
processing until input finishes and fresh response audio arrives. That failed
attempt remains recorded. Production session logic already keeps speech,
background activity, backend work and playback independent.

Run in `MIX_ENV=test` through the credential launcher:
`mix run scripts/gemini_interruption_live.exs /absolute/mono24k-interruption.pcm`.
The 40-second probe uses test channel/backend modules solely to observe the real
session's clear boundary; it does not place a call or execute a business action.


The [completion audit](qualification-audit.md) records the final requirement-by-requirement
assessment and repeated minimal SDK failure. The full-alternative goal is blocked,
not complete.

## HIGH thinking and wire-format follow-up

[The HIGH investigation](high-thinking-investigation.md) records five additional
bounded sessions: zero successful task answers. The offline production-versus-SDK
serialization audit found identical tool declarations and function-response
bodies. One minimal SDK session emitted a tool call but then spoke a system error;
its original loose `passed: true` flag must not be read as task success. The pilot
now requires the expected post-tool answer. Production defaults remain unchanged.

## Controlled comparison with standard 3.8 Live

[Ten new sequential SDK sessions](model-comparison/README.md), with matching tools
and model-appropriate thinking configuration, produced **5/5** successful fixture
answers on standard Live and **1/5** on Extended Thinking HIGH. All four Extended
failures occurred before a tool call. The one successful Extended run establishes
intermittency. This favors investigating standard Live in OrderDesk next; it does
not establish full provider parity or change the production default.
