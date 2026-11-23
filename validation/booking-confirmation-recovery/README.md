# Interrupted BookingDesk confirmation recovery

## Recorded failure

The November 23, 2026 manual GPT-Live-1.1 call booked one appointment at 91.7 s.
The assistant began `You're booked for`; the interruption was transcribed as
`Q-restirichekin`. At 94.7 s the scope guard cleared playback and asked for the
caller's request. The caller then said `I was waiting for the confirmation from you`
and `Is booked it`. Both delegations were associated with the completed booking,
without replaying its receipt. No adapter failed or booking was repeated.

The raw recording is retained locally under
`examples/booking_desk/runs/manual-gpt-live-11-20261123-132301`; it is not included
in this regression's source artifacts.

## Change and scope

BookingDesk enables `confirmation_recovery` only when selecting its OpenAI
provider. The call guard and its task-admission checks are unchanged. For a
completed, identity-bound booking, a status/repeat/retry interpretation can supply
the verified saved confirmation as a context message. It never starts or retries
a backend task. Pending/uncertain writes keep their existing protection.

An incomplete receipt routes otherwise non-actionable reminder replies through
booking interpretation, so status requests are not swallowed by the reminder
flow. Additional JEV guidance applies only to that explicitly enabled, unfinished
receipt state. Social replies and cancellation requests retain their own intents.

Recovery is bound to the original booking request, task revision, provider
generation and caller turn. Repeated policy callbacks cannot replay the same
request. Complete captions stop automatic status repair; an explicit repeat still
works because captions do not prove the caller heard the audio. Reminder opt-in
and destination consent remain separate.

## Regression coverage

`BookingDesk.BookingSessionTest` replays the original partial receipt, unclear
interruption, scope redirect and both follow-up requests against a real Parlora
session/coordinator and the demo database. It asserts the full verified code is
supplied, the appointment snapshot and job count stay unchanged, no new backend
submission appears, polling does not repeat the receipt, explicit repeat works,
and reminder opt-in does not send a reminder without number consent.

The regression fails at the first missing receipt when run with the pre-fix
`BookingDesk.Policy` from commit `7d3e86c`, then passes with the fix. Separate tests
cover the disabled path, OpenAI-only startup selection and pending-write protection.

## Live checks

- A real GPT-Live-1.1 BookingDesk replay passed all 14 existing workflow checks,
  including one booking, one reminder submission, date correction, readback before
  approval, and stale-result filtering. Its local capture is
  `/tmp/parlora-confirmation-recovery-workflow-20261123`.
- The read-only JEV probe recognized both recorded follow-ups as `progress`,
  `Repeat that` as `repeat`, `Thank you` as `none`, and a cancellation request as
  `cancel` (5/5 checks).
- Direct comparisons with pre-fix HEAD found identical Gemini/Grok/Phonic/Prism
  prompts, provider options, voices and limits. Default JEV questions are also
  byte-for-byte equivalent without the new explicit recovery flag.
- BookingDesk's full suite passed 309 tests, including the recorded-call regression.
  Parlora's full suite passed 773 checks (3 excluded); Python tests passed 28.
  Formatting, strict Credo and the zero-clone ExDNA check passed.

To reproduce the focused regression from `examples/booking_desk`:

```sh
mix test test/booking_session_test.exs --only interrupted_confirmation --warnings-as-errors
```

To repeat the read-only live semantics check with the existing Keychain launcher:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run ../../validation/booking-confirmation-recovery/semantic_probe.exs \
  /tmp/booking-confirmation-semantics.json
```

The live workflow verifies the normal booking/reminder path. The interruption
itself is replayed deterministically from transcript events; this is not a claim
that the original microphone audio was re-run or that model transcription quality
has improved.
