# Retry, correction clarification, and measured audio gaps — September 21

## Original call and attribution limits

`call-evidence.json` preserves the 15:34:31–15:36:13 browser call. All five jobs
completed and were accepted. No failure/overflow event was retained; after
disconnect `/health` reported zero active sessions. Order 124's saved instructions
became version 5, and the assistant announced the save.

The recognized sequence includes **134**, then “Are you sure”, “Just try again”,
and the correction “One hundred twenty four”. The captions do not establish
whether 134 was spoken or mistranscribed; no caller recording was retained.

Application clarification events occurred at 15:35:04, :12, :21 and :35. The
original per-fragment classifier inputs, scores and clarification markers cannot
be extracted through this launch's interface: the server has no private evidence
endpoint and no distributed node name. It was not restarted to investigate.

Thus the two application mechanisms below are **reproduced defects**, consistent
with the retry/correction symptoms, not recovered original scores or attribution
of every one of the four clarification events. The later :21/:35 events remain
unattributed individually. A constructed status-tail control settled successfully;
we do not claim it caused those events. The next diagnostic launch should export
bounded original policy judgments/markers privately so this distinction is
observable without relying on constructed history.

## 1. Explicit retries have no execution semantics

`Interpretation.intent_choices/1` has order status, work progress and continuation
choices, but no explicit retry meaning. With a completed status lookup for 134,
“Are you sure” followed by “Just try again” is distributed among those choices.
Two live TypeSafe controls selected `handled_continuation` at **.44/.46**, below
.8; order 134 remained known at **.94**. The policy consequently clarified instead
of starting another lookup. The exact clarification wording differs from the
original spoken wording and is not asserted to be identical.

There is a second deterministic failure even if classification is confident:
`AppPolicy.decisions/7` checks `same?(old, input)` using only order, operation and
instructions. A status/134 result is associated with the existing task; it does
not run again. `policy_replay.exs` injects a confident status/134 judgment and
asserts that the only action is `associate_delegation`. Without a pending
delegation, that association helper returns no action.

The library supports starting a fresh anchored task. The missing distinction is
in the example: *another execution of the same read* versus a duplicate provider
delegation or conversational progress question. An explicit retry needs its own
application interpretation and deduplication keyed to fresh caller input. It
must not turn repeated partial judgments/delegations into repeated backend jobs.

## 2. Number-only corrections bypass interpretation of the actual question

A low-confidence proposed status operation is retained as:

```
known_order: "134"
known_operation: nil
candidate_operation: "status"
missing: ["operation"]
question: "Do you mean the delivery status for order 134?"
```

`Clarification.number_reply/2` handles a complete number whenever operation is
missing. It changes `known_order` to 124 but preserves the missing operation and
candidate. `AppPolicy.do_interpret/3` uses that shortcut **before** invoking the
classifier. After the normal verification wait it asks:

> Do you mean the delivery status for order 124?

The deterministic control asserts that the classifier is never called, even
when the supplied classifier would resolve the correction as status/124. This
reproduces the repeated question precisely for that retained-marker shape.

The guard was designed for a genuinely unknown operation: a bare number must not
invent work. But it also captures a number correcting an explicit read-operation
confirmation question. Those cases need distinct handling. The correction should
reach interpretation with the actual outstanding question and proposed operation;
this does not mean blindly executing an uncertain operation or authorizing writes.

As a comparison, a constructed clarification with **known** status passes through
the classifier and supersedes 134 with 124. The explicit “Yes, what is the
de-delivery status” control also resolves status/124. Two live repetitions of
each passed the unchanged .8 threshold. These explain why a more explicit answer
can escape the loop, without proving the original scores or all original phases.

## 3. Audio: late upstream availability plus intentional recovery silence

Unlike the interpretation path, the new timing traces captured these gaps directly.
`audio-gap-3.json` and `audio-gap-14.json` retain aligned provider handling, reads,
channel writes, output ticks and completion observations.

All numbers below are milliseconds relative to the first silent output tick:

| Measurement | Gap 3, 15:34:43 | Gap 14, 15:35:39 |
| --- | ---: | ---: |
| Interval between adjacent provider audio arrivals | 190.128 | 215.610 |
| Next audio handled by provider adapter | 33.709 | 62.673 |
| First provider read with bytes | 43.070 | 65.002 |
| First channel write | 43.113 | 65.072 |
| First channel read observes available source | 50.042 | 70.158 |
| Channel queue observed full (9,600 bytes / 200 ms) | 89.952 | 109.973 |
| Actual extra recovery waiting | 129.905 | 129.867 |
| Measured silence interval | 179.947 | 200.025 |
| Generated zero PCM | 180 | 200 |

The provider queue was empty and repeatedly read as empty before the next batch.
Once it arrived, it moved to the channel within roughly 2–9 ms. Recorded output
pipeline work stayed below .5 ms and tick lateness below 2.2 ms during these gaps.
The trace does not support a 180–200 ms scheduler stall or a decoder stuck with
available source data. These arrival measurements occur in the local provider
adapter; they cannot distinguish remote model generation, network delay or work
before the adapter handles the message.

After source returns, `Parlora.Playout` deliberately holds recovery for **120 ms**,
regardless of queued byte count. Ten-millisecond output ticks make the observed
wait approximately 130 ms: the first tick near 120 ms fell just before the deadline.
The buffer filled well before playback resumed and blocked later transfers while
silence continued. No provider-pressure release occurred in either interval.

This is the current policy's tradeoff, not recurrence of the old shortage-doubling
formula. It is substantially shorter than some earlier holds, but it still adds
~130 ms to a 50–70 ms source shortage. Nonzero boundary peaks (6,752/6,592 and
5,024/4,192) make these actual inserted PCM gaps between substantial source samples.
No speaker recording identifies the exact affected syllables or proves perception.

### Recorded timing replay

`audio_replay.exs` runs production Browser.Media, Playout and Opus using the recorded
channel-write times and output ticks with synthetic PCM. It reproduces the gap
duration, inserted zeros and unavailable/recovery split **exactly** for both gaps.
The gap-14 recorder snapshot ends between the completion observation and that
same output call's playout telemetry; the replay uses the completion timestamp
for that final tick, explicitly documented in the script.

A zero-recovery control on the same schedules yields **50 ms and 70 ms** of
inserted silence. This isolates the extra hold; it is not a recommendation to
remove buffering. The control replays only the retained window and cannot prove
that immediate resumption would avoid later gaps, overflow or pacing problems.
Any tuning must preserve the recorded jitter, short-tail, queue-bound, overflow
and clear/epoch regressions. The software cannot play PCM that has not arrived.

## Validation and artifacts

- Two deterministic application assertions: number correction bypass and same-read
  retry deduplication.
- Eight bounded live TypeSafe classifications, retained in `policy-results.json`.
  Constructed snapshots; no GPT-Live session or saved data mutation.
- Four production media replays (two recorded schedules × current/zero wait),
  retained in `audio-replay-results.json`.
- Pinned macOS Elixir/OTP/Rust environment. No runtime implementation, server
  configuration, database or credentials changed during this investigation.

From the repository root:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
  mix run validation/browser-retry-20260921/audio_replay.exs
```

The policy replay runs from `examples/order_desk` with `ORDER_DESK_DATABASE=:memory:`,
`ORDER_DESK_TYPESAFE=1`, the same scheduler/Rust settings and
`python3 scripts/with_keychain.py mix run ../../validation/browser-retry-20260921/policy_replay.exs`.
It retrieves credentials through the existing wrapper without displaying them.

## Implemented fixes

The diagnosis sections above describe commit `8475f0f`. The following changes
address the reproduced mechanisms without assigning every original clarification
to a recovered model response.

### Application policy

- `retry_lookup` is an explicit semantic choice for a fresh attempt of the active
  read (status, items, or saved instructions). It creates a new task with the
  previous task/revision as its admission anchor, even for identical order input.
  The new task records the caller revision, so late delegations associate with
  it instead of creating another attempt. Progress remains association-only.
- Retries cannot replay delivery edits, refusals, or cancellation. Unsupported or
  uncertain judgments still clarify. The existing 0.8 confidence threshold is
  unchanged.
- A number-only reply to a proposed read confirmation reaches interpretation.
  The classifier sees the actual question and proposed operation, so correcting
  134 to 124 can resolve the read. There is no automatic promotion of a proposal
  into execution. Unspecified operations and write proposals retain the number
  only and still require clarification.
- Policy mapping remains entirely in `examples/order_desk`; Parlora's public
  context and task contracts are unchanged.

`fixed_policy_replay.exs` uses constructed snapshots in `policy_fixtures.exs`.
Two live TypeSafe rounds of six controls **all passed (12/12)**: explicit retry,
number correction to a proposed read, explicit status reply, status sentence
tail, progress question, and the trailing word of an already admitted retry.
Results are in `fixed-policy-results.json`. This is classifier evidence, not a
new voice acceptance call. The historical `policy_replay.exs` deliberately
asserts the old defects and is intended for the pre-fix implementation.

### PCM recovery

The default deadline remains 120 ms after source returns. Recovery can now end
when the channel queue is full **and half the deadline has elapsed** (60 ms by
default). Upstream pressure can still release earlier. Zero buffering, short
trailing audio, clear/reset, epoch handling, queue capacities, and source order
remain unchanged. `queue_ready` now identifies this full-cushion release in real
browser observations as well as the historical queue-policy control.

An initial experiment releasing immediately at full occupancy reintroduced the
second gap in the older long-jitter fixture. The half-deadline minimum preserves
its single-gap behavior, while reducing total inserted silence by 70 ms relative
to that fixture's legacy queue-triggered control (the prior fixed hold saved only
10 ms). No regression expectation for gap count or source conservation was relaxed.

| Latest recorded schedule | Historical hold | New rule | Source unavailable |
| --- | ---: | ---: | ---: |
| Gap 3: inserted silence | 180 ms | 120 ms | 50.042 ms |
| Gap 14: inserted silence | 200 ms | 140 ms | 70.158 ms |

`fixed-audio-replay-results.json` retains historical, zero-wait diagnostic, and
current-policy results. `test/recorded_recovery_test.exs` checks exact inserted
PCM counts, unchanged source-unavailable time, release reason, and source-byte
conservation after draining. Existing long-jitter tests preserve every source
sample and bound the queue. The overflow replay adds the current cushion policy
at ten output-clock phases; all ten conserve 52,800 source bytes without overflow,
while the historical 200 ms hold still reproduces overflow at all ten phases.

These traces cannot distinguish remote generation delay from network or work
before local adapter handling. They also cannot predict all future jitter or
confirm perceived speech quality. The 50/70 ms shortages remain; they are not
eliminated by this change. No new physical playback/listening result is claimed.

### Checks and running example

- macOS and Linux (`ssh linux`), pinned Elixir 1.20.4 / OTP 29.0.6: root `mix ci`
  passed, **206 tests, 3 excluded**, native checks, Credo/ExSlop, ExDNA zero-clone
  budget, Credence, and Dialyzer.
- Packaged-library example on both platforms: format and warnings-as-errors
  compile passed; **143 tests passed**, including a real coordinator/Jido retry
  producing exactly two tasks and associating a late delegation.
- Browser server restarted while idle at `http://localhost:4000` with the updated
  package. Existing SQLite data was preserved; `/health` reports zero sessions.
  New numeric audio traces go to `/tmp/parlora-browser-audio-trace-retry-fixed`.
- Validation logs: `macos-ci.log`, `linux-ci.log`, `macos-example-tests.log`,
  `linux-example-tests.log`.

Run the fixed policy probe from `examples/order_desk`:

```sh
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run \
  ../../validation/browser-retry-20260921/fixed_policy_replay.exs
```
