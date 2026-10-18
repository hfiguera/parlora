# Repeated replies: human call diagnosis, 2026-09-24

Historical diagnosis before the repairs. See [FIXES.md](FIXES.md) for the current
implementation, regression tests, live evidence and remaining limits. The replay
below intentionally asserts the old defects and is not expected to pass on the
repaired implementation.

Call: 17:31:03–17:32:19 America/Denver, session
`lV4V5J_dShuB6rSl1K8HEcjp`, standard `gemini-3.8-live`.
This is a diagnosis; no production behavior was changed.

## Evidence and limits

- Browser captions and observation log were read from the existing internal browser
  tab, without reconnecting or reloading it.
- The bounded provider metadata capture is copied to `metadata.jsonl`. It contains
  message fields, caption lengths, tool IDs, lifecycle signals and audio byte counts,
  not audio, caption text, tool arguments, credentials or resumption handles.
- The running consumer and the test consumer matched the repository's relevant
  session, policy, Gemini provider/protocol/call and save-announcement source files.
- Four offline diagnostic tests reproduce the application mechanisms against the
  real session and policy code, Gemini message builders, and save-announcement
  state machine. They assert the present defects, not successful fixes. See
  `replay_test.exs` and `replay.log`.
- Outgoing message bodies and save-worker state were not captured in the human
  call. Exact outbound timing is reconstructed from application events, the code
  paths and inbound responses, rather than claimed as a recorded outbound trace.
- Audio was not recorded. Captions and associated audio frames establish that the
  repeated output originated upstream of the browser caption renderer; they do
  not establish what the caller heard through the speakers.

## 1. Corrected status: two delivery paths for one result

Observed sequence:

| Local time | Evidence |
| --- | --- |
| 17:31:18.045 | Caption correcting 123 to 124 |
| 17:31:18.047 | New tool call `call_1677430` |
| 17:31:18.410–18.411 | One replacement backend job starts and finishes |
| 17:31:18, browser log | Result submitted, then `delegation_associated` |
| 17:31:19.294–19.717 | First “Order 124 is out for delivery.” generation |
| 17:31:21.810 | First turn completes |
| 17:31:22.772–23.044 | Second identical sentence, new generation with audio |

`OrderDesk.AppPolicy` supersedes the existing status task and schedules association
of the new delegation on a later policy pass. `Parlora.Session.Decisions` keeps
the old task's `delegation_id` when superseding. Consequently the replacement
result is delivered using the already-completed order-123 call ID.

`Gemini.Calls.context/3` converts a result for a completed call into a fresh
`clientContent` turn. Separately, association of the new call reads the same
completed job summary and resolves that call with a function response. Standard
Gemini schedules that response `WHEN_IDLE`. Thus the same status reaches the model
as both an application content turn and a later tool answer.

The first replay proves both messages contain the same result while only two
backend jobs exist (one for 123 and one for 124). It deliberately holds the new
delegation until after the replacement completes to deterministically exercise
the completed-result association path seen in the browser log; it does not claim
to reproduce the exact millisecond scheduling of the original call.

Required fix direction: one owner for delivery of a task revision's result;
associate/correlate the current call without making already-delivered business
content speakable again. Preserve necessary terminal tool responses and genuine
later results after clarification. Do not blindly suppress every completed-call
update.

## 2. Delivery instructions: model answer races the independent application lookup

| Local time | Evidence |
| --- | --- |
| 17:31:38.174 | “And what are the delivery instructions?” caption |
| 17:31:38.260–38.646 | Gemini generates the first answer, with audio |
| 17:31:38.860 | First answer generation completes |
| 17:31:39.153–39.154 | Instructions lookup starts and completes |
| 17:31:39.206 | Provider reports interruption |
| 17:31:39.756–40.443 | Gemini generates the repeated answer |

There was no tool call for this question. Gemini answered about 893 ms before
the new lookup started. Earlier status summaries already included the saved
delivery instructions (`OrderDesk.Lookup.describe("status", ...)`), so those
facts were available in its context. Reuse of those facts is a supported inference;
the model's internal reasoning is not captured.

Independently, `AppPolicy` interprets caller captions and may start a follow-up
without a delegation. That happened here, yielding a speakable result with no
call ID. `Gemini.Calls.context/3` sends such results as a new application content
turn with `turnComplete: true`. That second trigger follows the already-generated
answer. The offline replay confirms the application still sends that turn after
an early assistant answer; it does not require a duplicated backend job.

Required fix direction: coordinate who answers a fresh factual request and when.
The prompt says to delegate such requests, but the model did not do so here.
Narrower status summaries can reduce the opportunity to reuse unrelated facts;
prompting alone cannot enforce coordination. Do not treat an assistant's early
answer as proof that a fresh database lookup is unnecessary or correct.

## 3. Save repetition: wording mismatch leaves a retry pending

Saved literal: `left in my front door`.

First generated confirmation at 17:31:58.268–58.391:

> For order 124, the delivery instructions to leave it at your front door are now saved.

`SaveAnnouncements.confirmation?/2` requires the normalized exact saved text
inside the accumulated assistant caption. It normalizes punctuation, case and
neighbor/neighbour, but not `left`/`leave`, `in`/`at`, or `my`/`your`.
This actual caption therefore fails its check. The item remains pending and is
eligible for the configured retry, six seconds after the first submission.
The second attempt is an instruction update, which `OrderDesk.Provider` falls
back to speakable content for Gemini.

The second save sentence starts at 17:32:02.834. The server warned at
17:32:13.942 that the announcement ended without matching transcript evidence.
The deterministic replay feeds the actual first sentence to the matcher and
proves it retains the pending item and submits attempt two once eligible.

Required fix direction: align save-announcement wording and verification so that
normal pronoun/paraphrase changes do not cause blind repeat announcements. Keep
order, version, negation and destination safeguards; do not replace the matcher
with an unrestricted fuzzy match. Generated-caption evidence is never proof of
playback or hearing.

## 4. Save timing: a caption gap is mistaken for a safe speech pause

The Gemini adapter updates its private `activity` when audio arrives, but emits
the public `provider_activity` event only for protocol activity observations.
In this call the standard model supplied `turnComplete` (mapped to idle), but no
explicit `IN_PROGRESS` interaction status. Session health consequently remained
idle during later audio output.

`SaveAnnouncements.advance/1` only requires that public activity is not
`in_progress` and that no caption arrived for one second. It does not check
whether provider speech has finished or downstream audio is still playing.
Captions arrive much faster than the corresponding audio is played.

- Draft captions end at 17:31:54.969; generation completes at 54.970.
- The first save-related interruption appears at 17:31:56.112, before a natural
  completed turn. This fits the one-second caption pause plus tick/transport time.
- Save captions end at 17:31:58.391, but output audio continues afterward.
- Another interruption appears at 17:32:02.187, about six seconds after the
  first, matching the retry interval. The second save response follows.

The fourth replay proves that the observed no-interaction-status message shape
does not publish a new activity state and that the announcer submits after a
caption gap without requiring a completed turn or playback. The human-call
attribution of those interruptions to content submissions is strongly supported
by timing and code, but their exact outgoing frames were not retained.

Google's current [capabilities documentation](https://ai.google.dev/gemini-api/docs/live-api/capabilities)
states that a completed client-content turn interrupts generation. Its
[session-management documentation](https://ai.google.dev/gemini-api/docs/live-api/session-management)
defines generation completion separately. Neither caption silence nor generation
completion establishes completion of local playback.

Required fix direction: track background interaction, speech output and playback
separately; schedule application announcements using an explicit safe-delivery
policy. Preserve the Extended Thinking background-status semantics rather than
equating every turn boundary with idle for all models.

## Outcome and verification

The database save succeeded once: order 124 moved from version 2 to 3. All five
backend jobs completed, there was no reconnect or server crash, and the observer
survived disconnect. These issues affect response coordination and speech
delivery, not duplicate business execution in this call.

Run the diagnostic checks from the standalone consumer:

```sh
MIX_ENV=test RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
mix run /Users/humberto/Projects/parlora/validation/gemini/repeated-replies/replay_test.exs
```

Result: four diagnostic tests pass. No API calls or credentials are needed.
The first harness run had two failures because its classifier stub returned order
123 even for the recorded correction; the stub was corrected to classify 124.
The final replay log reflects the corrected harness. Production code and the
running server were not changed or restarted during this investigation.
