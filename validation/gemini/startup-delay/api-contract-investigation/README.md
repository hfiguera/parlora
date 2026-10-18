# Gemini API contract and pause isolation — September 24, 2026

Follow-up: [coordination repair and verification](../coordination-fix/README.md).
The findings below describe the pre-fix investigation; the linked reproduction
now asserts the repaired behavior. Remote delay causation remains unresolved.

## What is established

There are two findings. The long-pause behavior reproduces **outside Parlora**
against the raw Gemini WebSocket API, including with the immediately committed
OrderDesk prompt. Separately, OrderDesk can request an interrupting clarification
after Gemini has already asked the missing-information question. The latter is an
application coordination defect; it does not explain every recorded pause.

This identifies the remote Gemini processing/delivery boundary for independently
reproduced stalls, not Google's internal cause. It does not establish that every
human-call pause has the same internal mechanism. In particular, some probes
delayed input transcription while the human goodbye delayed output after an
already received transcript. No production fix is claimed.

## Matched committed/current prompt experiment

[The probe](../turn_probe.py) uses raw Python WebSockets, the application's setup,
16 kHz PCM16LE synthetic speech in paced 20 ms frames, and continuous seeded quiet
noise. Each session contains only a greeting and “Okay, thank you. Bye.” There is
no browser, Elixir, native resampler, observer, backend execution, clarification
injection, or save announcement. Authentication is an in-memory header.

Eight pairs alternated HEAD/current execution order. The two exported setups
diff only in the three new delivery-instructions prompt lines. Each run is a new
connection. These small samples establish reproducibility, not a production
failure rate or latency benchmark.

| Setup | Clip end → first reply audio, milliseconds | Over 5 seconds |
| --- | --- | --- |
| Committed `41a064e` | 1498, 1336, 1478, 1769, 852, **26512**, **19678**, 1108 | 2/8 |
| Current | 1046, 1339, 1760, **8495**, 1351, 1081, 909, 1017 | 1/8 |

The [26.512-second committed run](paired-5-head.json) returned WebSocket pongs
in 25–29 ms throughout the wait. Its input caption arrived 25.854 seconds after
clip end; reply audio followed 658 ms later. The
[19.678-second committed run](paired-6-head.json) reproduced the same broad
symptom again. Neither run had background task errors. This disproves the claim
that the uncommitted application changes or the diagnostic observer are required
for the long-pause behavior. Their removal can coincide with a successful call
without fixing an intermittent service interaction.

## Other bounded controls

- Current setup, fresh automatic-VAD sessions: 927, **9464**, 1211 ms after clip
  end. The slow run's pongs remained 26–33 ms.
- Current setup with explicit `activityStart` / `activityEnd`, sending audio
  **only inside that activity window**: 3766, 1522, **8294** ms. Consequently,
  replacing automatic VAD with explicit boundaries is not an established fix.
- Minimal prompt without tools: 1120, 1303, 973 ms in three trials. This is too
  little evidence to conclude prompt simplification fixes the problem.
- Linux, committed setup and identical synthetic WAVs: 1360, 903, 1261 ms. Those
  runs did not reproduce the stall. The credential was piped through SSH into
  process memory, not arguments or remote files.
- A multi-turn manual-VAD probe without clarification injections delayed a
  submitted tool result by **10.283 seconds**, and its goodbye audio arrived
  **8.645 seconds after transcription**. Pongs during those waits took 25–29 ms;
  there were no background task errors. That probe streamed audio outside the
  manual activity window as well, so the gated single-turn tests above are the
  cleaner manual-activity control. See
  [full events](manual-no-clarification-manual_no_updates-0.json).

Exploratory reports are retained, including negative results. Do not use
`realtime-text-realtime_all-0.json` as evidence of a fix: its stage-4 audio
preceded that stage's input, demonstrating cross-turn overlap in the exploratory
harness. Earlier `early-*` runs used WebSockets' default ping/compression and did
not retain background-task errors; their timeout alone is not decisive evidence.
Later probes explicitly disable compression/automatic pings, measure diagnostic
pongs, and report background failures. The final probe also records audio-send
counts/gaps; the earlier reports do not contain those measurements.
Four final committed-setup runs with these send measurements answered in
886–1158 ms; their maximum send gaps were 22–25 ms. They did not reproduce a
pause, so those send-gap numbers must not be attributed to the earlier slow runs.

## API audit

The implemented model, lack of thinking-level configuration, PCM encoding/rates,
20 ms sends, continuous automatic-VAD stream, `NON_BLOCKING` declaration and
correlated function responses conform to the documented interface. A transcript
is not an explicit user-turn-finalization acknowledgment. Proactive audio is
permanently enabled for this model, but that fact **does not prove** it caused
these particular pauses.

Google documents two relevant constraints:

1. `clientContent.turnComplete: true` interrupts active generation.
2. Mixing `clientContent` and `realtimeInput` has no guaranteed ordering/behavior.

Sources: [model-specific contract](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live),
[Live API reference](https://ai.google.dev/api/live#bidigeneratecontentrealtimeinput),
[capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities).
The first constraint is directly relevant to the clarification collision; the
second is a limitation, not proof that any supported clientContent use is invalid.

## Independently reproducible application defect

[clarification_overlap.exs](../clarification_overlap.exs) supplies a completed
items task, the new delivery-change request, and Gemini's already-spoken question
in the transcript. With a fixed semantic judgment that wording is missing,
AppPolicy still emits another clarification. Session.Decisions immediately sends
it; Protocol.text encodes it as an interrupting `clientContent` turn.
[Observed result](clarification-overlap.json).

This matches the live overlapping sequence: Gemini began its question at
19:03:01.599, the app submitted a clarification at 19:03:05.145, and Gemini
reported interruption 65 ms later before producing “...”. The metadata does not
retain the live clarification text or interpreter judgments, so the offline
fixed-judgment example is not presented as a replay of those missing values.

There is also a delivery-state mismatch: `ContextWait.clarify` records the
question's revision at submission, and AppPolicy later uses it to identify
answers to that question. Gemini only confirms the local socket write; the
question may not yet have been spoken. Coordination and delivery semantics need
repair. They must not weaken business validation or infer that a draft/save
succeeded from speech.

## Reproduction and remaining work

Use a temporary output directory because the probe generates synthetic WAVs:

```sh
/path/to/python-with-websockets validation/gemini/startup-delay/turn_probe.py /tmp/gemini-paired paired 8
```

The script privately reads `GEMINI_API_KEY` or the existing Keychain service.
The independent minimal reproduction is suitable for a Google issue after user
authorization to publish it; no report was submitted externally.

No human audio was recorded during this investigation. An explicit one-call,
three-minute local PCM-capture option was prepared but **not enabled** pending
the user's answer. Nine observer tests passed on macOS and Linux, including
capture opt-in, size limit, single-connection lifetime and file permissions.
The browser server was not restarted or altered during these API probes.

All retained JSON reports and source hashes are indexed in [manifest.json](manifest.json).
