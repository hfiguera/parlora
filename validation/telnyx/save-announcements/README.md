# Save announcements and delivery extraction — 2026-09-20

## Changes

`OrderDesk.SaveAnnouncements` is application-owned, supervised, and tied to one
session. BrowserGate forwards verified saves to it for browser and phone calls.
It waits for a 1,000 ms transcript pause before submitting a speakable update
that explicitly supersedes the earlier request to press Confirm. Acknowledgment
alone does not retire the pending announcement. Matching generated confirmation
text does; it does not prove playback or human hearing.

One instruction follow-up is permitted after 6 seconds and another pause. An
announcement expires after 20 seconds, including while speech continues. Limits
are two submissions, eight retained orders, one current pending version per
order, and a 2,048-character transcript suffix. Duplicate/older versions do not
resubmit. Session close/death stops the worker. Missing matches, rejected updates
and submission failures never undo the saved database state. Paraphrases can miss
the conservative transcript matcher, so a bounded duplicate announcement remains
possible; no exactly-once or guaranteed-hearing claim is made.

The delivery extractor accepts `let with/at/in/on ...` after a confident delivery
classification, preserving literal words for review. It still rejects unfinished
phrases and social `let me check` text. The classifier explicitly retains the
current order for an instruction edit without a new order reference. This does
not lower confidence thresholds or authorize saving. Voice instructions prohibit
claiming that a draft exists until the backend confirms creation.

## Evidence

- Consumer on macOS/Linux: 104 tests pass, compilation with warnings as errors and
  formatting pass. Tests cover mid-speech saves, acknowledgment without speech,
  one retry and finite expiry, fragmented confirmation, wrong-order/caller/negated
  speech, superseding versions, duplicate prevention, capacity and cleanup.
- `extraction.exs` / `extraction.log`: live TypeSafe selects delivery/order 124 for
  the exact reported phrase, with the literal destination preserved. Social
  `Let me check the page` remains `none`. `extraction-before.log` preserves an
  initial replay with target uncertainty before the prompt refinement.
- `live.exs` / `live.log`: bounded real GPT-Live test with a drain-only PCMU/8 kHz
  channel, matching Telnyx's negotiated format. It confirms an isolated in-memory
  proposal during the first assistant transcript fragment, without sending any
  caller prompt afterward. Generated confirmation is observed at ~15.6 seconds;
  shutdown has finalized usage. This exercises real provider audio and context,
  but does not exercise Telnyx transport, a handset, or physical speakers.

Run from the standalone consumer with `ORDER_DESK_DATABASE=:memory:` through
`scripts/with_keychain.py mix run`, followed by the absolute script path. The
classifier probe additionally needs `ORDER_DESK_TYPESAFE=1`. Scripts do not print
credentials. Only the live probe mutates data, in its required in-memory store.

## Preserved failure / remaining limit

Two earlier 24 kHz PCM probes using synthetic LocalAudio failed before completion.
`live-first.log` records a generic provider/session failure. The second run,
`live-pcm-overflow.log`, records provider `output_overflow` even when the macOS test
suite was no longer running. The first run's exact failure code was not retained.
This is not counted as successful validation, and its root cause remains open.
The PCMU test leaves the production buffer limits unchanged. Reproduce the PCM
variant with `PARLORA_SAVE_PROBE_FORMAT=pcm`; do not infer that its overflow is
fixed from the successful PCMU run. Historical successful-probe output includes
callback annotation warnings, corrected afterward without behavioral changes.

No new handset validation is claimed. Previously saved user data remains intact.

## Spelling follow-up — 2026-09-20

The next handset call announced the saved change automatically, but its caption
used `neighbour` while the saved text used `neighbor`. Exact destination matching
kept the announcement pending, causing an unnecessary follow-up and warning.
Replaying the original caption fragments through the production handler
reproduced this; changing only the spelling made the old matcher succeed.

Comparison now canonicalizes that whole-word spelling pair on both sides. Stored
instructions and outgoing context are untouched. It does not use fuzzy matching
or normalize `neighbourhood`. The recorded fragments now retire the pending
announcement; a wrong-order control remains pending. Regression tests cover both
spelling directions, split words, no retry after recognition, and wrong-order,
negated, caller-spoken and different-destination statements.

The updated consumer passes 107 tests on macOS and Linux, plus compilation with
warnings as errors and formatting. This follow-up uses recorded-event replay and
automated tests; it does not claim a new handset call or fix the separate PCM
probe overflow documented above.

## PCM investigation follow-up

The remaining PCM failure was reproduced with numeric telemetry. The synthetic
native device ran slower than its declared sample rate, causing downstream
backpressure and provider receive-capacity exhaustion. A 24 kHz PCM sink control
passed. See [the clock investigation](../../../docs/pcm-overflow-investigation.md)
for retained measurements, regression tests and the implemented clock correction.
The corrected PCM synthetic probe completed with finalized usage, no provider
overflow and no blocked output ticks. Three local playback-starvation events
remain documented; no production buffer limits were enlarged.
