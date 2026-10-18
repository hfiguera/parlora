# Human-call response stalls — September 24, 2026

Latest: [raw API contract investigation](api-contract-investigation/README.md)
reproduced 26.512- and 19.678-second pauses using the committed prompt without
Parlora, the observer, or backend work. A separate local clarification-coordination
defect was reproduced. This is stronger isolation evidence than the earlier
observer-on/off human comparisons below; it is not a claim of a production fix.

## Finding and confidence

The 18:28 recurrence locates a **60.032-second wait after successful backend
completion and result submission, before incoming Gemini reply audio/captions**.
Input transcription and delegation were prompt in that call. This excludes
microphone startup, application interpretation, backend execution and local audio
playback as the location of that minute-long wait. The remaining boundary is
provider response generation/delivery, including transport; its internal trigger
is **not proven**. A successful socket write is not a Google acknowledgment.

The earlier 18:18 call instead delayed its first input caption. The caller reports
stopping and waiting after requesting order 123. Later “Hello, are you there?”
was prompted by the missing response; it must not be blamed for causing the
initial delay. We cannot claim the two calls have the same internal cause.

For the earlier call, the retained evidence locates the observable delay before
the first incoming Gemini transcription. It does not establish when intelligible
microphone speech reached Google's service. There was no raw input recording,
signal-level history, or server-side speech-boundary acknowledgment in that call.

## Captured recurrence at 18:28

The user reported another pause during the instrumented call. The visible input
caption was “Sure, check the order 124.” This is the recognized order, not an
independent recording proving what number was spoken.
See [recurrence metadata](human-recurrence-metadata.jsonl).

| Event | Time |
| --- | --- |
| Greeting turn complete | 18:28:45.743 |
| Speech energy present before and after conversion | Approximately 18:28:46–48 |
| Input transcription | 18:28:49.213 |
| Backend tool call | 18:28:49.301 |
| Tool-request turn complete | 18:28:49.319 |
| Lookup starts, completes, and result is submitted | 18:28:49.775 |
| First reply caption/audio from Gemini | 18:29:49.807 |

There are 107 approximately half-second quiet windows after the request and
before later noise around 18:29:42. No frame crossed the diagnostic RMS threshold
of 328; the maximum frame RMS during those windows was 124.26. These are
measurements of forwarded input, not just microphone UI state. During the result
wait, 120 health samples continued and the socket recorded 2,982 additional writes
between the first and last of those samples. No receive/send error or reconnect
was recorded. Google eventually supplied the correct order-124 status/tracking
answer. Parlora did not hold an already-generated reply for a minute.

The app builds a correlated `toolResponse` with `scheduling: WHEN_IDLE` for this
initial result. There is no association/duplicate-call path before this result,
so the newly added `SILENT` association handling is not the applicable path.
The recurrence's observer did not retain the outgoing response structure, so this
is a code-path conclusion, not a raw outbound-packet capture. The final observer
now also logs response IDs, scheduling and response key names without values.

## Scheduling and schema check

Google's protobuf and SDK put `scheduling` alongside `id`, `name` and `response`;
Parlora follows that structure. The prose guide's nested example conflicts with
those schemas; moving the field inside the business-result object is not a
justified fix.
[Protocol schema](https://github.com/googleapis/googleapis/blob/master/google/ai/generativelanguage/v1beta/content.proto),
[SDK class](https://googleapis.github.io/js-genai/release_docs/classes/types.FunctionResponse.html).

[Direct-wire probe](scheduling_probe.py) used the exported current OrderDesk
setup, synthetic 16 kHz speech, a greeting, continuous seeded quiet noise (RMS 20),
and a 474 ms simulated tool delay. All three probes answered:

| Response variant | Result submission → first reply model turn |
| --- | --- |
| `WHEN_IDLE`, omitted `willContinue` | 933 ms |
| `WHEN_IDLE`, explicit `willContinue: false` | 662 ms |
| `INTERRUPT`, omitted `willContinue` | 739 ms |

See [full results and setup](scheduling-probe.json). These are three individual
attempts, not a performance comparison or proof of an intermittent scheduling
bug. They do not justify changing production scheduling to `INTERRUPT` or claiming
that explicit `willContinue: false` fixes the issue. `INTERRUPT` can interrupt
ongoing generation, unlike `WHEN_IDLE`.

## Earlier human-call evidence

Local times are America/Denver. See [machine-readable evidence](evidence.json)
and [original bounded metadata](human-metadata.jsonl).

| Event | Time |
| --- | --- |
| Gemini greeting turn complete | 18:18:07.766 |
| First incoming input transcription | 18:19:28.784 |
| First backend lookup starts | 18:19:31.301 |
| First backend lookup completes | 18:19:31.302 |
| First answer caption arrives | 18:19:32.992 |

The 81.018-second interval is **greeting completion to first caption**, not a
measured speech-end latency. The browser's caption combined the order request and
the later “Hello, are you there?” One provider connection remained open throughout.
All five backend tasks subsequently completed and the browser-confirmed save
updated order 124 to version 4. The repeated-reply defects did not recur in the
visible transcript.

There are 168 health samples before the first caption, at intervals no larger
than 502 ms. Every interval forwarded 49–51 ten-millisecond input frames and
recorded 25–26 successful socket writes. No receive/send error, audio overflow,
or interrupted provider connection was recorded. This rules out a continuously
blocked local send loop during the pause, but frame counts do not prove speech
content or Google's receipt of those frames.

Code inspection found a 200 ms input queue budget, a bounded browser jitter
buffer and decoded input queue, ten-millisecond resampler blocks, and continuous
20 ms Gemini sends. There is no local timer intentionally holding first speech
for 81 seconds. The application changes for correction, lookup result delivery,
and save announcements had not run before the first user request was admitted.

## Controlled reproduction

Four fresh calls used the current uncommitted application/library sources,
synthetic Samantha audio, real WebRTC, Gemini, TypeSafe and Jido, with isolated
databases. Every call correctly answered order 124; none reproduced the stall.
Consumer source hashes and timing results are in `evidence.json`.

| Attempt | Clip end → first input caption | Clip end → first answer caption |
| --- | --- | --- |
| 1 | 1,044 ms | 3,679 ms |
| 2 | 1,184 ms | 3,258 ms |
| 3 | 1,053 ms | 3,141 ms |
| Final timestamped observer | 1,080 ms | 3,427 ms |

These are browser-observed caption timings, not acoustic playback measurements.
The pilot configures a one-second order-124 backend delay. It bypasses the human
microphone/speaker environment and does not exonerate intermittent code defects.

## New diagnostics, no response-policy changes

The development observer now reduces input PCM immediately to half-second
aggregate counts, peaks, maximum frame RMS, signal timestamps and frame gaps,
before 24→16 kHz conversion and after conversion. It retains no audio, caption
text, tool arguments or credentials. The before-conversion metric is limited to
PCM input; μ-law is not incorrectly interpreted as PCM16.

The final observer uses Erlang source trace timestamps for signal measurements
instead of observer mailbox arrival time. The first three diagnostic runs used
observer receipt timestamps and are retained separately; do not read them as
precise conversion-latency measurements. In the final run both signal boundaries
arrived in the same network tick. Windowed maximum gaps were 21.452 ms before
conversion and 30.097 ms after it; these are not across-window maxima.

The RMS threshold (328, approximately −40 dBFS) is an energy marker, **not VAD**.
Noise and echo can also cross it, and quiet speech can remain below it. Successful
socket writes still do not constitute a remote audio-receipt acknowledgment.

Seven observer tests passed on macOS and Linux, including actual native audio
conversion tracing, silence and energy summaries, aggregate-only persistence,
backend result handling, closed sessions and observer failure isolation.

The idle human demo was restarted with signal capture; that produced the 18:28
recurrence above. No prompt,
VAD, buffering, database, or recovery policy was changed by this investigation.
The final observer, including outbound response structure, was deployed with
private capture at `/tmp/parlora-gemini-human-protocol-20260924/metadata.jsonl`.
It was subsequently stopped while idle for the human comparison below. The observer was disabled for the successful 18:49 trial and re-enabled at
18:52:36 for the matched reversal described below, using the same uncommitted
runtime and isolated test database.

## Protocol check and next evidence

Google documents automatic speech-boundary detection on continuous audio and
recommends 500–800 ms silence duration; the configured 700 ms lies in that range.
It also documents client-side VAD with `audioStreamEnd` as a hybrid option. Neither
is evidence that VAD caused this particular call. We have not added speculative
flushes that could cut off speech or change interruption behavior.
[Official capabilities guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities#voice-activity-detection-vad).

The human recurrence demonstrates that a long pause can occur even after Google
has transcribed the request and requested/completed backend work. Do not describe
every pause as missing input transcription or blame continued caller speech.
Remaining useful evidence is a matched recurrence with outbound correlation and
transport-liveness measurements, or Google-side request diagnostics. A bounded
application response watchdog is also warranted: the existing greeting progress
expectation is already satisfied and does not detect the later response stall.
No watchdog or automatic resend was added here; resending a result could create
duplicate speech and replaying a task could duplicate business execution.

## Immediate-commit regression comparison

The user's report that these pauses began with the uncommitted changes is a
credible regression hypothesis. Locating the wait after a provider socket write
does not exclude a prompt, result-content, scheduling or instrumentation change
as its trigger. Earlier comparisons against `7c134e3` do not test the current
diff against its immediate parent `41a064e`.

An isolated consumer at `/tmp/parlora-head-41a064e-human-ab` now contains all
tracked library, application and browser asset files from `41a064e`. It compiled
successfully and served `http://localhost:4000/` without the uncommitted
observer for the baseline trial. Its saved data is a SQLite backup of the demo database, not the original
database. The working tree and original consumer remain intact. File hashes are
in [the baseline manifest](head-human-baseline-manifest.json).

[The offline comparison](compare_initial_contract.exs) ran against both compiled
consumers. For the same synthetic initial lookup/result, the function-response
payloads are identical, including correlation and `WHEN_IDLE`. Setup is identical
except for the three added delivery-instructions prompt lines: model, tool schema,
VAD, captions, compression and resumption configuration match. See
[committed setup/result](initial-contract-head.json) and
[uncommitted setup/result](initial-contract-working.json).

The actual status-result text also changed: it no longer includes delivery
instructions. This comparison intentionally uses identical fixture text to
compare protocol behavior; it does not claim actual model inputs are identical.
Save announcement gating, speech events, correction association and the observer
remain additional changed behavior to isolate if the committed human call succeeds.

The human call at 18:46:32–18:47:41 did **not** reproduce the startup stall. The
first order-123 lookup completed at 18:46:40 and source reply audio resumed at
18:46:41 (browser display has whole-second precision). The caller also reported
normal startup. See [browser transcript and events](head-human-browser.json).
The call continued through correction to 124, items, clarification, and a
browser-confirmed save. This saved only the isolated database: order 124 is now
version 5 there; the original demo database remains at version 4.

This strengthens the regression hypothesis but does not identify a specific
change: both the runtime diff and diagnostic observer were absent. The next
arm, now serving localhost:4000, uses the uncommitted runtime with the observer
disabled and the same isolated database. The 18:49:21 human call **also started
normally**: the first order-123 lookup completed at 18:49:28 and source reply
audio resumed at 18:49:29. It continued through a clarification of the bare
number “124,” the correct order-124 status reply, and a goodbye. See
[observer-off browser evidence](working-no-observer-human-browser.json).

| Human runtime | New observer | Startup outcome |
| --- | --- | --- |
| Uncommitted, 18:18 | On (earlier metadata observer) | 81 seconds greeting → first input caption |
| Uncommitted, 18:28 | On (signal observer) | 60.032 seconds completed result → incoming reply |
| `41a064e`, 18:46 | Off | Reply audio resumes the second after first lookup completion |
| Uncommitted, 18:49 | Off | Reply audio resumes the second after first lookup completion |
| Uncommitted, 18:56 | On (final observer) | Incoming reply audio 725 ms after first result submission |

Before the reversal, the observer was the leading regression suspect; removing the application
fixes was not necessary for the successful 18:49 call. This is not yet a causal
proof: the prior on-trials used order 124 in the best-measured stall, while the
two off-trials started with 123, and a transient remote or network failure may
have changed between trials. A matched reversal with the same request, runtime,
data and observer version remains necessary. The expanded audio measurement
itself cannot explain the earlier 18:18 failure because it was added later;
investigate the shared tracing/sampling behavior before blaming that extension.
Do not treat successful baseline or synthetic probes as proof that an intermittent
failure cannot occur.

## Matched observer reversal — no stall reproduced

At 18:52:36 the same uncommitted consumer was restarted with the final observer
**enabled**, using the same isolated database as the 18:49 observer-off call.
The human call at 18:56:56–18:57:22 recognized “Sure, let's check the order 123.”
and answered normally. It then handled “Sorry, I mean 124” and a goodbye.

| Event | Local time |
| --- | --- |
| First input caption | 18:57:04.455 |
| First lookup result submitted | 18:57:05.465 |
| First reply caption | 18:57:06.177 |
| First reply audio payload larger than two bytes | 18:57:06.190 |
| Correction to 124 recognized | 18:57:12.499 |
| Correction result submitted | 18:57:12.509 |
| Correction reply caption/audio | 18:57:14.332 |

The initial result-to-caption interval was **712 ms**, and result-to-audio was
**725 ms**. The initial caption-bearing packet contained only two decoded audio
bytes; the audio measurement above uses the subsequent larger payload. These are
observer receipt times, not acoustic playback or speech-end measurements. The
browser reported resumed source audio at 18:57:06.

The first response used the matching call ID and `WHEN_IDLE`. For the correction,
application policy completed one lookup before Gemini's matching tool call
arrived; the late call was associated with that result and answered `SILENT`.
There were exactly two backend starts/completions, one for each requested order,
and one spoken answer per order in the transcript. No send/receive errors,
reconnection, or failed task was recorded. The correction response began
1.823 seconds after its result submission.

**This reversal did not support the prediction that re-enabling the observer
would bring back the stall.** The same uncommitted runtime now has successful
human calls both with and without the observer. This weakens the observer
hypothesis but does not rule out intermittent instrumentation effects or prove a
remote model fault. The root cause remains unresolved; no stall fix is claimed.
Earlier observer versions and requests differed, and the test count is small.
Further diagnosis needs a captured failure or repeated matched trials, rather
than attributing causality to the earlier sequence of failures and successes.

Evidence: [browser transcript](working-observer-on-reversal-browser.json),
[metadata](working-observer-on-reversal-metadata.jsonl),
[source-hash manifest](working-observer-on-reversal-manifest.json), and
[timing summary](working-observer-on-reversal-summary.json).
Nine local Gemini adapter tests also passed with the observer enabled; these do
not reproduce the human microphone or remote-service conditions.
The server remains on the uncommitted runtime with the observer enabled and the
isolated test database, ready to capture any recurrence.

## Later conversation stall after restart — 19:01–19:04

The call after the 19:00:35 restart reproduced long pauses **after normal
startup**, with the same current runtime and observer enabled. The first order
123 lookup, correction to 124, and items lookup all completed and were answered.

After Gemini asked for new delivery instructions, the application emitted
clarifications at 19:02:20.152, 19:02:26.153, and 19:02:42.264. The first next
incoming answer was at 19:02:52.881, 32.729 seconds after the first clarification
submission. Browser source audio was unavailable for 32.813 seconds between
turns; this is not a measured speech-end latency. Input captions arrived at
19:02:23.410 and 19:02:39.179 during the gap. The displayed combined caption was
“Poder leer with my neighbor. Are you there? Hello.” No raw microphone recording
establishes the exact words spoken.

The 65 health samples between the first clarification and next reply show 3,205
additional input frames and 1,606 socket writes, with sample intervals at most
505 ms. No socket error was recorded. There was no pending slow backend execution
in this interval: the previous items lookup completed at 19:02:08.849; the next
backend request was the delivery draft at 19:03:12.480.

A second overlap is visible: Gemini asked what the new instructions should be at
19:03:01.599. The application's clarification update at 19:03:05.145 preceded a
provider interruption at 19:03:05.210 and an output caption containing just “...”
at 19:03:06.183. Code inspection confirms that session clarification immediately
calls provider.append_context; Gemini encodes a speakable non-tool update as a
completed user clientContent turn. Clarification dispatch does not coordinate
with provider_speech or recognize an already spoken Gemini question. This is a
concrete overlapping-dialogue path to investigate, but the captured sequence alone
does not establish that it caused the 32-second gap. Outbound clarification text
and interpreter judgments are not retained in the metadata observer.

The draft subsequently completed in 3 ms. Gemini announced it 1.190 seconds
after result submission. The user confirmed it in the browser; the isolated
order 124 record became version 6 with “Live with my neighbor.” That is the
caption/draft/save text, not an independently verified transcription of intent.

There was **another delay on goodbye**: “Okay, thank you. Bye.” was transcribed
at 19:03:31.727, but the reply started at 19:04:00.020 (28.293 seconds later).
There was no intervening tool call or application clientContent update. Therefore
clarification overlap cannot by itself explain every pause in this call. The
call ended at 19:04:05. It is not a passing end-to-end test, and no stall fix or
single root cause is established.

Evidence: [initial live snapshot](later-stall-browser.json),
[completed browser transcript/events](later-stall-browser-latest.json),
[complete bounded metadata](later-stall-metadata.jsonl).
The server remains running with diagnostics, capturing to
`/tmp/parlora-gemini-current-restart-20260924-1901/metadata.jsonl`.
