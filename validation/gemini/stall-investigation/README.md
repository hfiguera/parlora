# First-request stall investigation — 2026-09-24

## Human observation and limits

The 17:02:26–17:02:55 call greeted correctly, transcribed “Sure, check the order
124. Hello? Are you there?”, and supplied no subsequent assistant answer. The
caller reports that the follow-up speech came because the first request went
unanswered, using speakers in a quiet room. It must not be treated as the cause
of the initial stall. The browser showed no delegation or backend-start events;
application interpretation counters were zero. Saved records did not change.
There were no recorded browser errors or server failure messages.

The original call did not retain Gemini wire events or input audio measurements.
Caption availability proves recognized speech, not end-of-speech detection or
response generation. Absence of retained evidence cannot identify a model,
endpointing, echo, transport, or code-regression trigger with certainty.

## Uncommitted-change comparison

[Comparison evidence](comparison.json) records all six fresh WebRTC calls using
real Gemini, TypeSafe and Jido, with the same synthetic Samantha request:
“Sure, check the order one hundred twenty four.” Each call had its own database.
The phrase was substituted by a Node preload in both runs; audio hashes and the
consumer source hashes are retained. The baseline consumer was a separate local
copy with the complete runtime app/lib/browser sources restored from commit
`7c134e3`; the working tree and user database were not rolled back.

| Runtime | Successful lookup and answer | First input caption → delegation |
| --- | --- | --- |
| Uncommitted working tree | 3/3 | 811 ms, 363 ms, 1 ms |
| Committed HEAD | 3/3 | 267 ms, 4296 ms, 1 ms |

These are observed caption-to-event delays, not acoustic latency benchmarks.
The first caption may itself arrive late. Six synthetic passes do not reproduce
the human speaker/microphone path, exclude intermittent regressions, or establish
that either version is reliable in that environment.

Diff review found unchanged input-audio pacing/conversion, VAD configuration,
tool schema, tool-call parsing and greeting code. Before the initial delegation,
the new provider code adds caption identities and boundary resets. The expanded
voice prompt is the main changed model-facing input. Thus prompt-induced behavior
is a remaining regression hypothesis, not an established cause. New correction,
clarification and draft-extraction branches are not reached before the first
pending delegation or admitted task.

## Two reproduced application gaps (also present in HEAD)

[Replay](admission_replay.exs) and [output](admission_replay.log) establish:

1. With no task and no pending provider delegation, recognized order-request
   captions return no policy action. The interpreter is not called. A later
   “Hello?” also does not unlock admission. Injecting the missing delegation
   immediately invokes interpretation and starts the correct order-124 status
   lookup. This is a dependency on provider delegation, not evidence that the
   interpreter or backend is hung.
2. The application arms a startup `until: :conversation` expectation. The greeting
   satisfies it, and later silence does not rearm it. The replay uses an 80 ms
   deadline, waits beyond it, and confirms the session remains ready with zero
   jobs. This explains why the interface can remain connected while no work is
   happening; it does not explain why Gemini initially produced no response.

Both behaviors predate the uncommitted changes. No production behavior was
changed or purported fixed by this investigation.

## Bounded capture enabled for the next human call

[Development observer](trace.exs) and [launcher](serve.exs) capture:

- Incoming Gemini message/part names, lifecycle flags, transcript lengths and
  `finished` flags, tool IDs/names/cancellations, and encoded output-audio counts.
- Successful socket-write counts, forwarded input/output counts, provider
  activity, admission counts and progress-expectation state every 500 ms.
- Selected session events and transport failures.

It writes no microphone PCM, caption text, tool arguments, context text, API key,
SDP/ICE values, or resumption handles. Files use 0600 and the directory 0700.
Capture is bounded to 10,000 records / approximately 8 MB (one final record may
cross the byte threshold); the normal app still limits calls to 180 seconds.
The observer does not alter prompts, tool admission, VAD, or recovery behavior.
Eight real loopback adapter tests passed under capture, and a sanitization check
verified omission of synthetic secrets. See [socket check](trace_socket_check.log).
A separate session replay verified public health sampling and event capture.

The current Gemini server was restarted with this observer. The next call's
private metadata is at `/tmp/parlora-gemini-human-stall-20260924/metadata.jsonl`.
Its saved-order database remains the existing user's development database.
The comparison baseline is available separately at
`/tmp/parlora-stall-head-consumer-20260924` for a matched human A/B test if needed.

## Protocol reference

Google documents automatic VAD on continuous audio, with end-of-speech detection
controlled by `silenceDurationMs`; the configured 700 ms is within its recommended
500–800 ms range. Captions do not independently prove that the model has finished
waiting for speech. An `audioStreamEnd` flush is supported for paused streams or
hybrid VAD, but no such intervention was silently added here.
[Official guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities#voice-activity-detection-vad),
[wire reference](https://ai.google.dev/api/live#bidigeneratecontentrealtimeinput).

## Follow-up human call: diagnostic observer crash at 17:21:10

The next human call did not repeat the missing-delegation stall. Captions reached
Parlora at 17:21:10.150; Google sent `delegate_to_backend` at 17:21:10.370, and the
backend started at 17:21:10.904. Browser events show backend completion and result
submission (`unconfirmed`) immediately afterward.

The observer introduced during this investigation then crashed at 17:21:10.906:
`e.payload[:cause]` invokes Access, but the completion payload is a
`Parlora.BackendResult` struct without that behaviour. The observer was linked
to the Mix launcher, so its exit terminated the server and closed the browser
call. This is an instrumentation regression introduced after the original 17:02
stall; it cannot explain that earlier event. The exception also printed the
backend result in the server crash log, contrary to the intended metadata-only
capture. No credentials or microphone audio were in that event.

The observer now reads fields with `Map.get`, starts unlinked from the launcher,
and redacts its crash status/message. A dead observer is skipped by the provider
ready hook. [Four regressions](trace_test.exs) pass: completed/failed result structs,
a real Jido lookup through context delivery under capture, forced observer death
without killing its owner, and omission of private values from summaries/status.
See [results](trace_regressions.log). The earlier replay stopped after task
submission and therefore missed the completion-payload bug.

The Gemini server was restarted with the corrected observer. New private capture
uses `/tmp/parlora-gemini-human-stall-fixed-20260924/metadata.jsonl`; the failed
call's prior capture remains preserved. The original missing-delegation trigger
remains unproven.

## Successful human flow: 17:24:57–17:26:00

The next call completed status 124, correction to status 123, the items follow-up,
and delivery-draft creation: four backend jobs completed, with three TypeSafe
calls, two cache hits, and zero interpretation failures. The late correction
provider call was associated with existing work rather than creating another job.
The browser showed the literal draft `left with my neighbor`; its confirmed save
updated only order 123 from version 2 to 3. A separate assistant caption announced
the saved result, followed by a goodbye and user disconnection. The original
missing-delegation stall did not recur; this single success does not establish
its cause or elimination. Captions also added the packaging word “bags” to the
stored item `Coffee beans` (quantity 2), a small unsupported detail.

At 17:26:00.542, after disconnection at 17:26:00.213, a queued observer sample
received `{:error, %Parlora.Error{code: :closed}}` from `Parlora.status/1` and tried
to access it as a map. The isolated observer failed; the application remained
healthy. Sampling now accepts closed/unavailable replies and stops sampling that
session. A new regression covers both a live process returning `:closed` and a
terminated process. All five observer regressions pass. The server was restarted
with this cleanup fix; next-call metadata uses
`/tmp/parlora-gemini-human-stall-close-safe-20260924/metadata.jsonl`.
# Optional one-call audio capture

Metadata-only observation remains the default. For an explicitly authorized
diagnostic call, the development launcher accepts `PARLORA_STALL_RECORD_PCM_ONCE`
pointing to a new private file outside the repository. The observer records only
the first provider connection's converted PCM16LE mono 16 kHz input, at most
180 seconds of audio. It closes the file on provider exit or reaching that bound;
later connections cannot append. Creation is exclusive and permissions are 0600.
No PCM is included in the metadata JSON or retained in observer state. This option
was prepared during the API-contract investigation but has not been enabled.
