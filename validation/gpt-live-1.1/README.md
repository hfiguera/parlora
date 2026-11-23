# GPT-Live-1.1 compatibility comparison

## Results — November 23, 2026

All four cases passed in [results.json](results.json): GPT-Live-1 and GPT-Live-1.1,
each using PCM and PCMU. Each case emitted two delegations, acknowledged both mock
results, transcribed both speakers, recovered with the selected model, and received
final usage plus a graceful-close acknowledgment from the replacement connection.
No provider failures or command rejections were observed. The local suite passed
773 checks (7 properties and 766 tests), with 3 excluded.

This confirms that the stored development credential can access 1.1 and that the
existing adapter protocol works with it. It does not demonstrate a quality or
latency advantage over 1.0. Following the BookingDesk validation below, 1.1 is now
the OpenAI default; explicit 1.0 selection remains supported.

## BookingDesk workflow validation

All three recorded-caller workflows passed all 14 checks in
[workflows.json](workflows.json):

| Model | Scenario | Result |
| --- | --- | --- |
| `gpt-live-1.1` | Dr. Lee, corrected date, booking and reminder | Pass |
| `gpt-live-1.1` | Any doctor, select Dr. Patel, booking and reminder | Pass |
| `gpt-live-1` | Explicit rollback with token-based handoffs | Pass |

Each workflow uses actual voice, identity extraction, JEV judgments, Jido actions
and an isolated in-memory demo database. The checks require the assistant's opening,
conversation during lookup, a corrected task revision, stale-result filtering,
proposal readback before approval, the exact appointment, one proposal, one booking
submission, one simulated reminder submission, and no adapter failures. No real
SMS is sent. Raw fictional recordings remain in the capture directories identified
in the report; only summarized evidence is included here.

The full local suites passed: Parlora 773 checks (3 excluded), BookingDesk 305 tests,
BookingDesk Python 28 tests, and OrderDesk 249 tests using this branch's library.
Formatting and strict Credo checks passed for Parlora and BookingDesk. BookingDesk's
lint command loaded the existing root `ex_slop` beam path to satisfy the inherited
plugin configuration; no dependency or lint configuration was changed.

OrderDesk's older local vendored package initially failed a scripted clarification
test. That test passed against clean latest main, and the full suite passed in an
isolated consumer with this branch's library. The original vendored copy was left
untouched. The temporary baseline checkout was removed after validation.

[provider-isolation.json](provider-isolation.json) records direct comparisons with
`origin/main`: Gemini, Grok, Phonic and Prism retain identical prompt text, provider
options, voices and limits. Their adapter implementations and the shared session
coordinator are unchanged.

To reproduce the live workflows from `examples/booking_desk`, using the existing
synthetic caller clips and Keychain launcher:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run run.exs /tmp/booking-live11 clips/reminders

PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk \
  mix run run.exs /tmp/booking-live11-anydoctor clips/reminders --any-doctor

PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
python3 ../../scripts/with_keychain.py --booking-desk mix run -e \
  'r = BookingDesk.Run.run("/tmp/booking-live10", "clips/reminders", provider_options: [model: "gpt-live-1"]); unless r.passed, do: System.halt(1)'
```

## Method

This bounded probe runs both `gpt-live-1` and `gpt-live-1.1` over the real
`Parlora.Providers.OpenAI` adapter, each with PCM16LE/24 kHz and PCMU/8 kHz.
It uses model-specific delegation prompts from OpenAI's
[prompting guide](https://developers.openai.com/api/docs/guides/live-prompting#recommended-prompt-structure).

The synthetic caller asks for order 123, corrects it to 124, then asks in Spanish
to repeat the delivery date. Delegations receive a fixed, fictional lookup result;
no business service is called. After 31 seconds the probe injects an expired output
frame to exercise the adapter's recovery path, then closes gracefully at 42 seconds.
Four cases run concurrently, with at most two original sessions on each model.
Each recovery creates a replacement voice session.

The automatic checks require generated audio, caller and assistant transcripts,
delegation in the lookup and correction intervals, acknowledgment of every supplied
result, recovery with the same model, no rejected commands or provider failures,
and a provider-confirmed graceful close of the replacement session. The logical
session's `finalized?` remains false and cumulative usage has `complete?: false`
because forced recovery discards the original, unfinalized transport. The probe
checks that this uncertainty is retained. Transcript content must be inspected separately: phase-based
mock results do not verify that an application extracted the right task arguments.
First-audio time is measured from the start of the audio loop, including one second
of leading silence and caller speech. Continuous output can contain silence, so
this measures frame arrival and is not a speech/response-latency benchmark.
Final usage may remain incomplete across forced transport replacement, as documented
by the adapter's recovery contract.

## Reproduce

On macOS with Samantha and Paulina voices and `ffmpeg` installed:

```sh
python3 validation/gpt-live-1.1/prepare_audio.py /tmp/parlora-live11-audio
python3 scripts/with_keychain.py mix run validation/gpt-live-1.1/probe.exs \
  /tmp/parlora-live11-audio /tmp/parlora-live11-results.json
```

The launcher obtains the existing OpenAI development credential through
`/usr/bin/security` and passes it only in the child process environment. Reports
contain synthetic transcripts and aggregate event metadata, not credentials or
provider session identifiers. The probe never opens a microphone or plays audio.

## Limits

This is an adapter compatibility probe. It does not establish human conversation
quality, accent/pronunciation quality, noisy-call performance, interruption timing,
production capacity, or every BookingDesk path. The additional workflow replays
establish the booking/reminder paths described above; cancellation, failure and
consent edge cases are covered by the local application tests. Continue to evaluate
real callers, languages and noise conditions in the application's deployment.
