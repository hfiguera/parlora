# BookingDesk reminder readback and caller suffix echoes

## Root cause

The November 23 manual call at
`examples/booking_desk/runs/manual-approval-fix-20261123-141816` saved one booking
and no reminder. It reached `reminder_opt_in` normally. Two application decisions
then caused the loop:

1. At 143.4 seconds the readback repair rejected the correct destination question,
   `Great, one moment. Can we send it to the number ending in zero one eight eight?`
   `Reminders.readback_digits/1` scans the whole assistant turn, so the conversational
   word **one** contributed an extra digit: `10188`, instead of `0188`. This triggered
   an unnecessary correction while the caller started answering.
2. The caller echoed the suffix before approving it: `188? Yes, that is my number`,
   then `eight? Yes, this is my number`. A question mark vetoed literal approval;
   uncertain semantic interpretation fell through to the new-phone extractor.
   At 158.9 seconds it retained an incomplete phone fragment. That pending fragment
   blocked subsequent destination approval, including `Yes, I confirm that is my
   phone number`, and caused repeated requests for a complete replacement number.

The assistant also claimed to be scheduling before the backend accepted consent.
The booking was never duplicated, and no SMS was actually sent.

## Fix and boundaries

`reminder_recovery` is enabled only for OpenAI. Other providers retain their
prompts, options and original decision paths.

- Reminder readback checks remove only complete, explicitly allowed neutral
  introductory sentences. The remaining digits must still match the exact stored
  suffix, or all ten digits for a replacement. Wrong, incomplete, ambiguous and
  conditional questions remain invalid.
- A caller's short numeric echo can refer to the suffix already read back. It
  cannot supply a replacement number. Echo handling requires the current completed
  reminder task/request, a later destination question, a later caller turn and the
  current provider generation. Captions with question marks, commas, hyphens or
  no separator are covered.
- Only an explicit, unconditional approval following that echo can confirm the
  stored destination. A bare echo, uncertainty, refusal or condition grants no
  consent and never enters the new-phone extractor. Existing pending phone evidence
  is preserved and still blocks selection of the stored destination.
- Separate opt-in, exact destination checks, full replacement-number extraction
  and readback, the 1.5-second settling window, backend task handoffs, pending-write
  protection, store revision checks and booking deduplication are unchanged.
- OpenAI's prompt now asks for a brief acknowledgment while reminder approval is
  validated and prohibits scheduling/saving claims before the application result.
  The replay caller uses the same OpenAI readback validation as the live policy.

## Regression coverage

The recorded-call session regression uses the real coordinator, policy,
conversation memory and SQLite store with a controllable provider/backend. It
replays the full booking, reminder opt-in, the `one moment` question and the
fragmented `188? Yes, that is my number` answer. It verifies no false correction,
one reminder confirmation, one saved booking, one simulated reminder, and no
duplicate write when the caller repeats approval while the reminder is pending.

The regression fails on `82a2dc8` at the false readback-correction event. Its
companion appends a refusal during the settling window and verifies no reminder
is scheduled, even with an intentionally incorrect affirmative semantic judgment.
Focused cases also cover uncertain/bare echoes, conditions, wrong suffixes,
unverified questions, stale requests/generations, pending replacement fragments,
and full replacement-number consent.

## Reproduce

From `examples/booking_desk`:

```sh
mix test --warnings-as-errors
mix test test/booking_session_test.exs test/reminder_policy_test.exs --only reminder_echo
mix run --no-start ../../validation/booking-reminder-recovery/provider_comparison.exs
```

The comparison uses the committed approval fix as its baseline. It checks all four
other providers' prompts, provider options, voices and limits, and compares **960**
unscoped reminder decisions against that baseline.

Full live workflow, using existing Keychain credentials and an in-memory demo DB:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run run.exs /tmp/reminder-workflow clips/reminders
```

The suffix-echo variant changes only the synthetic caller's destination answer.
It uses macOS Samantha and ffmpeg, without opening the microphone or speakers:

```sh
python3 ../../validation/booking-reminder-recovery/prepare_audio.py \
  clips/reminders /tmp/reminder-echo-audio
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run run.exs /tmp/reminder-echo-workflow /tmp/reminder-echo-audio
```

No real appointment service or SMS provider is connected to these runs.

## Validation results

- Full BookingDesk suite: **328 passed**. Parlora: **773 passed**, including seven
  properties, with three hardware/live/stability checks excluded. Python: **28 passed**.
- Strict Credo, zero-clone ExDNA, strict Unicode Credence, compile-cycle checks,
  formatting and `git diff --check` passed.
- Other-provider comparison: four identical configurations and **960** identical
  unscoped reminder decisions. Shared Parlora code, the consent veto, store and
  reminder persistence code are unchanged.
- Normal live GPT-Live-1.1 workflow: **14/14** at
  `/tmp/parlora-reminder-recovery-workflow-20261123`.
- Synthetic suffix-echo workflow: **14/14** at
  `/tmp/parlora-reminder-recovery-echo-20261123`. Its actual caller caption was
  `One-eight-eight, yes, that is my number`, prompting additional deterministic
  coverage for captions without question marks.
- Final latest-code suffix-echo workflow: **14/14** at
  `/tmp/parlora-reminder-recovery-echo-final-20261123`. It completed with one booking,
  one simulated reminder, and no adapter failures. Destination approval reached the
  backend without the partial-number clarification loop.
