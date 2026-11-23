# Booking approval followed by an acknowledgment

## Recorded failure

The November 23, 2026 manual call in
`examples/booking_desk/runs/manual-confirmation-fix-20261123-133943` stopped with a
proposal and no booking. Its approval sequence was:

- 76.5 s: `Yes, please` answered the exact November 5, 10:15 AM, Dr. Lee proposal.
- 77.6 s: The app was still in its 1.5-second approval-settling window.
- 78.9 s: `'Kay` followed the assistant's acknowledgment and replaced the caller
  text being classified. It was judged uncertain, and the app asked for approval again.
- 91 s: `Yes, I already told you` was also judged uncertain, prompting a third question.

The assistant had claimed processing before any `confirm` task was admitted. This
is distinct from interrupted receipt recovery, committed first as `92b4cb2`.

## Fix and consent boundaries

BookingDesk enables `approval_continuity` only for OpenAI. Other providers keep
their original prompts, settings and interpretation questions.

For the same verified, pending **booking** proposal, `BookingDesk.Approval` derives
an actionable reply from the retained transcript when only short neutral
acknowledgments follow it. It does not store an authorization or cache consent.
The original caller words remain the actionable request; acknowledgments are
separate evidence. A scoped JEV intent question evaluates that reply against its
original question. Date/time/clinician questions and confidence gates are unchanged.

Continuity requires the current proposal ID and revision, current provider
generation, speech after that proposal's caller boundary, valid ordered timestamps,
and at most three acknowledgments spanning at most five seconds with the approval.
The readback must finish before the approval. The existing readback evaluator must
independently verify the exact appointment and permission question. A later question,
changed proposal, missing source speech or uncertain readback stops continuity.

All existing literal refusal/condition checks, semantic confidence gates, patient and
insurance binding, current proposal validation, expiry checks and pending-write
protection remain active. A bare acknowledgment cannot authorize a booking. The
1.5-second settling window remains, including after an acknowledgment, so a fresh
refusal or correction can still invalidate an in-flight interpretation. Cancellation,
rescheduling and reminder consent retain their existing paths.

The OpenAI voice prompt also asks for a brief acknowledgment while validation runs,
and prohibits processing/submission claims without an application-reported state.

## Validation

- The session regression replays the recorded proposal, `Yes, please`, assistant
  acknowledgment and `'Kay`, without inventing a second delegation. It admits one
  `confirm` task, asks no new approval question, and saves one booking. A later
  repeated approval cannot submit another write.
- The same test fails at the missing booking when run with the pre-fix policy from
  `92b4cb2`; its refusal companion still blocks booking despite a deliberately
  incorrect high-confidence classifier result.
- Safety tests cover conditions, refusal, corrections, questions, bare acknowledgments,
  missing/stale speech, changed proposals, wrong appointment fields, low-confidence
  answers and unavailable readback checks.
- Full suites passed: BookingDesk **320 tests**, Parlora **773 checks** (3 excluded),
  and Python **28 tests**. Formatting, strict Credo and the zero-clone ExDNA check passed.
- The live read-only probe passed **6/6** checks using real JEV/readback judgments:
  the recorded continuation and frustrated affirmative resolved to exact proposal
  approval, while bare acknowledgment, condition, refusal and date correction did not.
- The normal full GPT-Live-1.1 booking/reminder replay passed **14/14** checks.
  Capture: `/tmp/parlora-approval-continuity-workflow-20261123`.
- The targeted real-audio acknowledgment replay passed **9/9** checks: the injected
  `Okay` was transcribed before booking admission, the booking used the newer caller
  cursor, no approval question was repeated, exactly one booking was submitted and
  saved, the full verified receipt was spoken, no reminder was sent without consent,
  and no adapter failed. Capture:
  `/tmp/parlora-approval-continuity-targeted-final-20261123`.
- Direct comparisons against `92b4cb2` confirmed identical Gemini, Grok, Phonic and
  Prism prompts, provider options, voices and limits. Unscoped JEV questions are
  byte-for-byte equivalent. Shared Parlora code, consent vetoes and store logic are unchanged.

An additional full-call acknowledgment probe stalled after insurance review, before
reaching approval or injecting audio. Its partial capture remains at
`/tmp/parlora-approval-continuity-live-ack-20261123`. The targeted live fixture starts
with application-verified demo registration to isolate this call's approval state;
it does not bypass booking consent or execute a real-world appointment/SMS action.

## Reproduce

Focused deterministic session regression, from `examples/booking_desk`:

```sh
mix test test/booking_session_test.exs --only approval_acknowledgment --warnings-as-errors
```

Live semantic checks with the existing Keychain launcher:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run ../../validation/booking-approval-continuity/semantic_probe.exs \
  /tmp/approval-semantics.json
```

Targeted live audio check (macOS Samantha and ffmpeg), from the same directory:

```sh
python3 ../../validation/booking-approval-continuity/prepare_audio.py /tmp/approval-audio
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run ../../validation/booking-approval-continuity/live_ack.exs \
  /tmp/approval-live /tmp/approval-audio
```

That fixture uses the actual OpenAI adapter, call guard, JEV, coordinator, Jido and
demo database. It injects an `Okay` clip during the pending approval window, after
the model's acknowledgment, and checks that its transcript precedes one booking
submission without another approval question. Audio is synthetic and locally recorded.
