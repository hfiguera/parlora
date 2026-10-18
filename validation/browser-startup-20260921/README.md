# Intermittently silent browser startup — September 21

## Evidence and limits

The user's 13:35:29 call reached Ready at 13:35:31 but showed no transcript before
13:35:47 disconnect. The server had no startup failure. A bounded headless Chrome
call reproduced the silence: `before.json` contains no transcript, an empty job
and delegation set, flowing RTP with no loss/concealment, and decoded audio energy
near zero. This is a silent opening, not a stalled microphone-permission dialog.
It does not explain the remote model's internal decision to stay silent.

Two further calls with the unchanged opening greeted successfully. A diagnostic
subscriber observed the greeting instruction acknowledgment and subsequent
transcript in both. The failed call predates that subscriber, so its instruction
acknowledgment is **unknown**, not inferred from the later successes.

`observe.exs` is the temporary diagnostic launcher used for those controls. It
uses private BrowserGate state only to discover sessions, subscribes through the
public API, and prints event types/command IDs without transcript, PCM, headers
or secrets. It is not a runtime application dependency.

## Correction

BrowserServer previously submitted only “Speak first in English…” and ignored
the submission result and acknowledgment. It did not use the stronger bounded
opening already implemented for the phone examples.

The application now shares that implementation as `OrderDesk.Greeting`:

- Explicitly greet immediately without waiting for the caller, then listen.
- Subscribe before submission and check admission.
- Await the matching instruction acknowledgment, at most five seconds.
- Submit one speakable kickoff after acknowledgment unless speech was already
  observed. Do not kick off after rejection or session exit.
- Log submission, acknowledgment and timeout/rejection outcomes. Submission or
  acknowledgment is not playback evidence.

The phone callers were updated to the shared module name without changing their
opening sequence. This is application startup policy, not provider-adapter logic.
There is no unlimited retry and no new provider or audio-transport behavior.

The bundled GPT-Live documentation describes the instruction/ack/commentary
sequence in `docs/gpt-live-1/live-conversations.md`. The current official
[greeting guidance](https://developers.openai.com/api/docs/guides/live-conversations#greet-before-the-caller-speaks),
fetched September 21, emphasizes one immediate greeting instruction, matched
acknowledgment and continuous input audio; it no longer includes the optional
commentary paragraph in the bundled snapshot. The additional kickoff here is the
existing application policy from the phone examples, verified below, not a claim
that current OpenAI guidance requires it.

## Validation

`probe.cjs` uses a disabled synthetic microphone track (silence), not physical
microphone input. It connects through the real page/WebRTC channel to GPT-Live,
waits 12 seconds after readiness, collects captions and RTP statistics, then
explicitly disconnects. Reports omit SDP/candidates and credentials.

```
EXPECT_GREETING=1 PROBE_OUTPUT=/tmp/greeting-check.json \
  node validation/browser-startup-20260921/probe.cjs
```

Three consecutive corrected calls passed assertions for assistant transcript,
non-silent decoded audio, no browser exceptions and no failure/context-rejection
events. Each produced one short order-check greeting, 1.68–2.22 seconds after
readiness. See `after-1.json`
through `after-3.json`. These are live network tests with silent synthetic input,
not human listening tests or a guarantee of future provider behavior.

The regression suite checks browser wiring to the supervised helper, matching
acknowledgments, suppression after early speech/rejection, bounded timeout and
session-exit cleanup. Application format/compile checks and all **133 tests**
passed on both macOS and Linux. See `linux-checks.log` for the Linux run.

The corrected server is running at http://localhost:4000 with the existing
saved order database preserved. Optional audio timing traces continue under
`/tmp/parlora-browser-audio-trace-greeting-fixed`; the normal application launcher
still works without tracing.
