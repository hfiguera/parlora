# Items follow-up and browser gaps — September 21, 2026

## Scope

The manual call at 12:36:38–12:37:59 completed six jobs and saved order 123's
delivery instruction. It also requested clarification after an items lookup,
and recorded seven source-queue gaps. `call-evidence.json` preserves the visible
captions and diagnostic panel. No runtime behavior was changed for this diagnosis.

The normal server log contains startup messages, not policy judgments or audio
arrivals. The running app has a bounded private in-process interpretation evidence
buffer, but this non-distributed `mix run` launch exposes no retrieval endpoint.
We did not restart the app or add a public debug endpoint. Consequently the
original per-fragment timestamps, task admission snapshots, classifier scores,
and provider/channel arrival timings were not available to this investigation.
The replays below use constructed state, clearly separated from the original call.

## 1. A completed request's trailing word becomes a new uncertain segment

The caller's visible items request is split around an assistant backchannel:

1. Caller: “Do you know what items are”
2. Assistant: “Hmm,”
3. Caller: “there”

The backend job completed and its result was accepted at 12:37:11. Context waits
followed, then the application requested clarification at 12:37:14. The assistant
asked whether the caller meant order 123, and answered after “Yes”. This is not
evidence of a stuck or failed backend lookup.

The example's `AppPolicy.latest_input/2` uses the active task's `user_revision` as
the cutoff for new text. A task admitted on the prefix therefore leaves only
“ there” in `new_caller_text`. `current_input/2` reconstructs number continuations,
and another guard handles refusal continuations; there is no equivalent handling
for this ordinary sentence continuation.

`CallerHistory` inserts a segment boundary when an intervening assistant fragment
does not overlap the surrounding caller fragments, or when timing is unavailable.
Thus a brief “Hmm” can make `latest_caller_segment` also become “ there”. The
classifier still receives the full history and the handled prefix: this is not
total context loss. However, its instructions emphasize the latest segment when
selecting new intent. A task boundary and a backchannel combine to present a
sentence suffix as the primary new request.

### Live TypeSafe controls

`policy_replay.exs` made eight read-only calls using the current model, prompts,
and unchanged 0.8 confidence floor. Each variant ran twice:

| Constructed state | Intent score | Target score | Policy outcome |
| --- | --- | --- | --- |
| Prefix, previous status lookup | 0.96 / 0.96 | 0.97 / 0.97 | Start items/123 |
| Complete question before admission | 1.00 / 1.00 | 0.99 / 0.99 | Start items/123 |
| Items completed on prefix; separated “there” | 0.57 / 0.52 | 0.96 / 0.94 | Ask “Do you mean the items for order 123?” |
| Same completed task; overlapping backchannel | 0.96 / 0.93 | 0.99 / 1.00 | No new job or clarification |

All selected intents were `items` and targets were `123`. The separated-tail case
failed **intent confidence**, not order identification. A deterministic injected
uncertain judgment also proves that the expired verification phase produces this
question after completed work. The recovery delay rechecks the same unresolved
suffix; waiting longer does not reconstruct it.

This reproduces the symptom and isolates a concrete application segmentation
weakness. It does not prove the original fragment timestamps or original scores
were identical. Scores are model outputs, not calibrated correctness probabilities.

The first draft of the replay omitted the production `instructions: nil` field
from constructed tasks, which made the same-operation control incorrectly look
different to `same?/2`. The fixture was corrected and the policy outcomes recomputed
from the eight saved responses; no additional API requests were made. That field
is omitted from classifier input by `describe_task/1`, so classifier inputs did
not change. Cached replay asserts input equality before reusing answers.

### The misleading “it doesn't list any items here” wording

The status backend response intentionally omits items; the items operation returns
the actual item list. Neither adapter path returns a claim that order 123 has no
items. The spoken wording is provider-generated, not a database result. Its exact
generation cannot be reconstructed from captions. Treating missing item information
in a prior status answer as empty inventory would be an unsupported inference.
The eventual correct item list and accepted job show the database path worked.

The correction belongs in the example's request-continuation interpretation:
preserve the semantic relationship between an admitted prefix and its trailing
words while still accepting genuine new requests. Do not lower confidence checks
or blindly ignore every short follow-up. Distinguish facts not yet queried from
an empty result in the voice response instructions.

## 2. Recovery can extend a short source shortage by 200 ms

The new diagnostics establish actual substituted PCM intervals. The two with
substantial nonzero boundary samples were:

| Gap | Inserted silence | Peak before / after (PCM16) |
| --- | --- | --- |
| 1, 12:36:47 | 230 ms | 5,568 / 1,480 |
| 5, 12:37:30–31 | 270 ms | 7,680 / 8,256 |

The five remaining intervals were 260–290 ms with zero or near-zero boundary
samples (maximum observed peak 43). Boundary levels do not locate words or prove
speech was clipped, and these are pre-Opus server measurements rather than a
recording of the browser speakers.

When source playback exhausts its queue, `Playout` enters recovery. With current
defaults, `buffering?/3` waits **200 ms after the next available frame**, even if
the queue already contains the 120 ms initial cushion. The pipeline may release
the hold early only under upstream queue pressure. Normal source-queue exhaustion
does not itself tell this policy whether a phrase ended or speech is continuing.

`audio_replay.exs` drives production Browser.Media/Playout/Opus with regular 10 ms
ticks. It inserts synthetic source shortages and compares the existing recovery
wait with a test-only zero-wait control:

| Source returns after empty | Production recovery | Test-only no recovery |
| --- | --- | --- |
| 30 ms | 230 ms inserted silence | 30 ms |
| 70 ms | 270 ms inserted silence | 70 ms |

These controls prove local recovery can account for the extra 200 ms and show
that a 230–270 ms gap need not mean an equally long network/provider stall.
They do **not** recover the original first-frame arrival times or establish that
the original gaps used the entire hold; early pressure release and scheduling
can affect it. The initial queue depletion in the actual call remains unattributed:
provider scheduling, network arrival, pipeline draining, and local timing were
not recorded alongside these intervals.

The original wall-clock durations closely match inserted PCM durations, but this
alone cannot exclude local scheduling effects. No fatal output overflow or failed
call was visible. Do not remove recovery wholesale based on these controls: the
existing recovery/jitter tests document the repeated gaps that the hold prevents.
Further tuning needs aligned provider arrival, channel refill, first-return, and
recovery-release measurements, with bounded queues and jitter replay controls.

## Reproduce

From the repository root, use the pinned toolchain and macOS Rust/BEAM settings:

```sh
mix run validation/browser-followup-20260921/audio_replay.exs
```

From `examples/order_desk`, re-evaluate the saved live answers without credentials
or network calls:

```sh
ORDER_DESK_DATABASE=:memory: mix run \
  ../../validation/browser-followup-20260921/policy_replay.exs --cached
```

To deliberately repeat the eight live TypeSafe requests:

```sh
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
python3 scripts/with_keychain.py mix run \
  ../../validation/browser-followup-20260921/policy_replay.exs
```

The cached replay, deterministic policy assertions, and four audio controls passed
on macOS. `policy-results.json` and `audio-results.json` contain their evidence.
No voice session was opened, no stored order was edited, and no raw audio or
credentials were written. This is diagnosis, not a runtime fix or new Linux/audio
quality certification.

## Correction and validation

The sections above preserve the **pre-fix investigation**. The following changes
address the demonstrated interpretation failure and excessive recovery wait;
they do not identify the original live queue-depletion cause or certify speaker
output quality.

### Example-owned request continuation

OrderDesk's classifier now has a `handled_continuation` choice for admitted
read-only status/items/instructions requests. Its instructions explicitly connect
the handled prefix to trailing words across an assistant backchannel. The policy
accepts this only for the same known order and read-only task, without an
outstanding clarification or a changed/conflicting order reference. It associates
late delegations without another lookup. Confidence remains 0.8 for both judgments;
no public Parlora interface or business operation was added.

A streaming integration regression waits for the items job to **finish**, then
sends “Hmm” / “there”, waits beyond the clarification windows, and verifies no
clarification or third job. A late delegation is claimed once; a subsequent
status question still starts new work. Additional guards cover conflicting
numbers, changed targets, write operations, and low-confidence judgments.

Voice instructions also distinguish a status result which omits items from an
explicitly empty items result. This constrains the model's response; it is not a
guarantee against every unsupported generated statement.

`policy-fix-results.json` retains fourteen live TypeSafe responses (two runs of
seven constructed controls), separately from the eight historical responses:

- Both separated “there” tails confidently selected `handled_continuation` for
  order 123, with no new work or clarification.
- Both explicit status follow-ups started a status lookup.
- Both delivery edits entered the existing delivery-settle path.
- The other eight responses (elliptical order correction, missing target, ambiguous
  operation, cancellation of completed work) were below confidence threshold and
  requested clarification. They were **not swallowed as continuations**, but this
  is **not** a claim that all fourteen utterances were confidently understood.
  The evidence records exact-judgment matches separately from continuation guards.

`verify_policy.exs --cached` checks the saved inputs, judgments, and policy
outcomes without credentials. Omitting `--cached` deliberately repeats fourteen
read-only classifier calls through the normal Keychain wrapper. No GPT-Live
session is needed. The original `policy_replay.exs --cached` remains an historical
control showing how the old uncertain answers cause clarification.

### Adaptive, bounded PCM recovery

Playout now records the first empty-queue observation and first returned source
frame. Its refill hold is:

```
min(recovery_cap, max(initial_cushion, observed_shortage_duration))
```

At default settings, it waits 120–200 ms after source returns, rather than always
200 ms. It keeps the 200 ms/queue-duration cap, pressure-triggered early release,
short-tail deadline, zero-buffer option, clear/reset behavior and sample order.
No provider, pending-batch or channel queue was enlarged. A full destination queue
alone still does not release recovery: that trial reintroduced a repeated gap in
the longer recorded fixture and was discarded.

`audio_replay.exs` now compares an explicit historical-hold control, current
production Media/Playout/Opus and a zero-hold control. It writes a separate
`audio-fix-results.json`; the original `audio-results.json` is preserved.

| Synthetic queue shortage | Historical inserted silence | Adaptive inserted silence |
| --- | --- | --- |
| 30 ms | 230 ms | 150 ms |
| 70 ms | 270 ms | 190 ms |
| 190 ms | 390 ms | 380 ms |
| 500 ms | 700 ms | 700 ms |

The short controls remove **80 ms of added silence**, without claiming to remove
all gaps. Recorded-arrival regressions retain the single remaining gap at source
position 1,200 ms in the first fixture and 10,100 ms in the longer fixture. In the
longer fixture the adaptive wait adds 60 ms versus the old no-recovery control,
compared with 70 ms for the fixed hold. Source bytes/order and finite queue bounds
remain asserted. The forty burst/recovery phase controls still reproduce the
historical overflow and pass with production pressure release.

### Checks

- macOS and Linux `mix ci`: **202 passed, 3 excluded** on each, including native
  checks, Credo/ExSlop, zero-clone ExDNA, Credence and Dialyzer.
- macOS and Linux example application: **130 tests passed** on each using rebuilt Hex packages.
- Offline macOS Chrome smoke: three connect/control/disconnect cycles, zero packet
  loss or steady inserted silence, permission/origin rejection, and signaling-loss
  cleanup passed. See `browser-smoke-results.json`; this uses synthetic media.
- Twelve deterministic Browser.Media/Opus recovery controls passed on macOS.
- Fourteen saved live TypeSafe outcomes replay successfully under the continuation
  guards described above; only six were confident exact semantic matches.

No new human listening test, physical Linux audio test, or complete live voice
acceptance run is implied by these checks. The original call's provider-arrival
and channel-refill timestamps remain unavailable, so its initial depletion cause
is still unproven.
