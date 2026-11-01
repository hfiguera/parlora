# BookingDesk call boundaries

BookingDesk is a fictional US clinic receptionist demo. These controls limit the
example; they do not establish clinical triage accuracy or production readiness.

## Caller handling

- **Receptionist scope:** appointments, registration, stored insurance details,
  reminders, basic administrative preparation, progress and brief social exchanges.
  Baseball, trivia, biographies, coding, roleplay and instruction overrides receive
  a short scheduling redirect. After two delivered redirects, another off-topic
  request gets an announced closure. Returning to scheduling is allowed.
- **Possible current medical emergency:** give US 911/local-emergency-number
  guidance immediately, without collecting name/DOB or continuing scheduling.
  The example cannot call, dispatch, or transfer to emergency services. The guard
  enters a terminal emergency state, blocks scheduling, stops further caller input
  reaching the speech provider and closes the clinic call after emergency guidance
  and a software-playout quiet interval. It can override an abuse closing before
  the call ends. The caller should hang up and dial 911 immediately rather than
  wait for our closure. This behavior is for the scheduling demo, not an actual
  connection to a 911 dispatcher.
  Historical, negated and hypothetical symptoms are distinguished from current
  danger; this remains a model judgment, not diagnosis.
- **Non-emergency clinical questions:** explain that the receptionist cannot give
  medical advice, direct the caller to a qualified professional, and offer scheduling.
- **Directed caller abuse:** deliver one clear warning. Continued abuse after that
  message gets a polite closing statement and application-controlled termination.
  Frustration, criticism, a lone swear word, quoted abuse, accent and communication
  difficulties are not, by themselves, directed abuse. Emergency guidance takes
  priority when a distressed caller swears. No police notification or removal from
  patient records is claimed or performed.

## Enforcement and bounds

`BookingDesk.start/2` installs one supervised `CallGuard` per session. Shared speech
instructions apply to all four providers. The application policy consults the
controller **before** identity extraction, intent interpretation, new task admission
or releasing existing task results, including when no tool delegation exists yet.
Pending or rejected guard judgments cannot authorize new work. Previously admitted
side effects may still finish; clearing speech or ending a call is not a rollback.

JEV `jev-1.13.0` judges current emergency status and caller conduct using bounded
recent dialogue. It receives no patient list and has no write or hang-up authority.
Application code owns counters, current caller/generation bindings and closure.
The defaults are a 650ms debounce, a 2.5-second judgment deadline, no model retry,
48 evaluations per call, and a shared eight-task capacity. Low-confidence conduct
cannot count as confirmed abuse. Failed classification holds scheduling and uses a
bounded unavailable message/closure. Stale results cannot authorize a warning.

Warnings are not multiplied by repeated checks or fragments arriving while the
warning is still being delivered. A warning with no observed delivery is not
counted as a delivered strike. Terminal messages wait for assistant captions,
nonquiet output and a software-playout quiet interval (1.5 seconds). A 20-second
message deadline prevents an unresponsive provider from leaving the call open
indefinitely; a bounded extra classification window lets a new emergency report
preempt closure. Unobserved message delivery is logged as unconfirmed. These observations do not
prove human hearing or guarantee the exact wording a live model generates.

The controller forwards the original PCM and observation timestamps to an existing
recording tap with bounded credits. It retains level/timing flags, not raw audio;
explicit recording remains the runner's responsibility. Replay and microphone
channels use the same `audio_observer` option so the guard sees software playout
before forwarding it to the recording tap. Guard event telemetry
records bounded decisions, never caller quotes or classifier probabilities.

## Important limits

Once emergency-closing mode starts, the assistant must not offer a new lookup,
ask for name/DOB or claim that it is checking a file. Providers supporting live
instruction updates receive an explicit persistent mode instruction; every
provider receives the same terminal context and an input-mute request. Task
admission stays blocked even if a provider rejects muting or the instruction.
Tests prevent later identity input from reopening scheduling or postponing closure.

The safety classifier sees provider transcripts. ASR mistakes, classification
errors and streaming speech before a boundary decision remain possible. Shared
provider instructions are the first response layer; the controller can clear
queued output and submit a trusted redirect, but cannot retract speech already
heard. This is not pre-playback moderation of every generated audio token.

There is no connected human transfer, emergency dispatch or clinical triage service.
A real deployment needs the clinic's approved wording and escalation paths,
location-appropriate emergency handling, clinical review and testing on the actual
telephony transport. This example's software-playout check does not establish
physical playback on another channel. The runner retains its 210-second demo limit.

## Test it

After exporting the voice-provider, OpenAI extractor and JEV keys, from
`examples/booking_desk`:

```sh
PARLORA_PROVIDER=openai BOOKING_DATABASE=:memory: \
mix run run.exs "runs/guard-microphone-$(date +%Y%m%d-%H%M%S)" clips --microphone
```

Use fictional scenarios, headphones and a fresh call for each terminal/emergency
case. Try a baseball question followed by a real appointment request; ordinary
frustration; a directed insult, then another after the warning finishes; and a
clearly fictional emergency test. The application prints `Call guard: ...` when
it redirects, warns or closes. Press Enter to save and stop. Microphone summaries
report observed outcomes, not a scripted pass/fail grade.

Offline regression tests make no model calls:

```sh
mix test --warnings-as-errors
```

## Guidance used

- [911.gov: Calling 911](https://www.911.gov/calling-911/): immediately dial 911 in
  an emergency and follow the emergency call-taker's instructions. This scheduling
  example is not an emergency dispatcher.
- [MedlinePlus: Recognizing medical emergencies](https://medlineplus.gov/ency/article/001927.htm):
  examples of warning signs and the importance of prompt emergency assistance.
- [Parliamentary and Health Service Ombudsman: managing challenging situations](https://www.ombudsman.org.uk/organisations-we-investigate/complaint-standards/nhs-complaint-standards/good-complaint-handling-guides/managing-challenging-situations-complaint-handling):
  calm, clear warnings and explaining possible termination when abuse continues.
  This is communication guidance; the demo's one-warning policy is an application
  choice, not a statement of US legal requirements.
- [SCFHP provider access training](https://www.scfhp.com/media/p/3750/timely-access-to-care-training.pdf)
  gives automated office-line emergency wording directing callers to hang up and
  dial 911. It does not establish a universal rule requiring automatic disconnection;
  closing after the message is this demo's explicit policy choice. Once connected
  to an actual 911 dispatcher, callers should follow the dispatcher’s instructions
  about staying on the line.
