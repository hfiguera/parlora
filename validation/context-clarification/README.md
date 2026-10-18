# Clarification timing diagnosis

Investigated September 17, 2026 after a human browser call requested order
123, corrected it to 124, then returned to 123. The original diagnosis is followed by the implemented fix and regression evidence below.

## Observed call

The browser transcript contained “No sorry, go back to 123”, followed by the
assistant asking which order number to check and then saying it had order 123.
The displayed events were:

- 19:39:49: `context_wait_started`.
- 19:39:51: `clarification_requested`.
- 19:39:51: the third request started, completed, and advanced to awaiting provider.
- 19:39:52: the third result was accepted by the provider.

The final status/tracking answer matched order 123. The application console did
not retain per-interpretation inputs or TypeSafe answer probabilities. Browser
captions merge fragments and event times have one-second display resolution.
Consequently, the historical evidence cannot distinguish a still-incomplete
number from a low-confidence/unknown judgment on the completed correction.

## Confirmed original mechanism

1. `OrderDesk.AppPolicy` maps unknown/uncertain interpretation to
   `wait_for_context` with a 1,500 ms recheck.
2. `Parlora.Session.ContextWait.schedule/2` installs one timer per target revision.
   If a `context_wait` already exists it keeps that timer. Further caller text
   revises the snapshot but does not restart the wait.
3. After expiry, another unresolved judgment makes the application immediately
   return `request_clarification`. It does not establish that the caller has
   finished speaking or that uncertainty has persisted on stable caller input.
4. `Decisions.clarify/2` immediately appends that question as **speakable** provider
   context. This is an actual outgoing instruction, not a locally pending prompt.
5. A subsequent successful interpretation supersedes the task and runs the
   corrected lookup. Supersession clears local wait/clarification metadata but
   does not retract the already submitted provider context. The provider then
   receives the clarification followed by the result.

This is an application recovery-policy mismatch with streaming input and
probabilistic interpretation. The generic recheck timer is being treated as a
sufficient basis for asking a question. The session's revision check rejects
obsolete policy results; it cannot reject a question that was current when sent
or undo speech already prompted by that question.

Contributing details: TypeSafe rejects chosen probabilities below 0.8, uncertain
results are cached for 500 ms, and cache misses add 200 ms before the service call.
The policy runs on more than caller input (including assistant transcript and
context changes). A later judgment can therefore resolve uncertainty without a
new caller answer. SQLite lookups have no delay by default, exposing the two
provider updates in quick succession. These details do not establish the exact
TypeSafe answer or timing in the historical call.

## Original offline reproduction

Run from a materialized standalone consumer with its dependencies installed:

```sh
cd /Users/humberto/Projects/parlora_consumer
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin MIX_ENV=test \
mix run /Users/humberto/Projects/parlora/validation/context-clarification/verify.exs
```

The current script verifies the corrected behavior. It uses the real application policy, session coordinator, Jido backend,
and in-memory SQLite, with synthetic audio and scripted classifier/provider. It
makes no external API calls, changes no saved orders, and closes its sessions.

Before the fix, a characterization probe on the pinned macOS toolchain observed:

| Case | Evidence |
| --- | --- |
| Streaming correction | More caller text after 900 ms left the original deadline unchanged. Clarification arrived at 1,501 ms; the revision-3 result followed 2 ms after supplying the final number. |
| Complete correction, temporarily uncertain classification | Complete “go back to 123” text still produced clarification at 1,501 ms. A successful recheck without new caller speech produced the revision-3 result 2 ms later. |

Both original scenarios demonstrated separate clarification and result contexts reaching the
provider. Scripted classifications isolate coordination behavior; they do not
reproduce historical model probabilities, confidence-cache timing, or audible
provider output.

## Fix direction

Keep business clarification in the application's ContextPolicy. Separate a
bounded recheck from the decision that it is appropriate to speak a clarification:
consider caller-input progress and current interpretation evidence, suppress an
obsolete pending question when the request resolves, and retain a finite recovery
path when it genuinely remains ambiguous or the service fails. Simply increasing
1,500 ms shifts the race and adds delay. Test ongoing fragments, temporarily
uncertain complete corrections, and genuinely missing numbers independently.


## Implemented correction

Parlora now supports an optional bounded `recheck_key` on `wait_for_context`.
Changing it replaces the one timer for that target; repeated keys retain the same
wait, and obsolete timer messages cannot expire a replacement. Existing policies
that omit the key retain their earlier behavior.

OrderDesk owns the recovery phases and keys them by the newest caller fragment:
1,500 ms to settle, followed by a 600 ms verification window and a fresh classifier
call bypassing cached judgments. New unresolved caller input renews settling.
A successful interpretation cancels the superseded task's wait and submits the
corrected lookup without first asking. If a question has already been sent, the
policy waits for newer caller input before allowing a changed interpretation to
answer it. Unrelated events cannot cause the immediate question/answer flip.

Regression coverage includes continued corrections, transient uncertainty on
complete text, genuine ambiguity with a subsequent number-only reply, new input
during an in-flight verification, service failure, cache bypass, timer replacement,
obsolete expiry messages, key bounds, and compatibility with unkeyed policies.
No timer can establish that a human has finished speaking, and model judgments can
still be wrong. This fix does not retract questions or audio already delivered.

## Verification after the fix

On September 17, 2026:

- macOS `mix ci`: 108 passed, three separately tagged stability tests excluded;
  native checks, Credo/ex_slop, ex_dna, Credence, and Dialyzer passed.
- Standalone consumer: 20 tests passed on both macOS and Linux.
- Linux targeted coordinator/legacy-example tests: 17 passed.
- Default-duration offline replay: the continuing correction renewed its deadline;
  both it and the complete-but-temporarily-uncertain correction delivered the
  revision-3 order-123 result without a clarification. Runs completed in 2.65 and
  2.81 seconds, including the 700 ms check for unexpected additional context.

The replay uses a scripted classifier; a new human GPT-Live/TypeSafe call remains
necessary to assess the actual conversation experience. Existing physical-audio
and external-network limitations are unchanged.

## Missing-number reply recovery (September 17 follow-up)

A later human call omitted the order, replied “One, two, four”, repeated “One
hundred twenty four”, and asked “Do you check it”. Its work status showed two
pending delegations and no jobs, despite spoken assurances that a lookup was
running. Per-judgment TypeSafe results were not recorded, so the historical
judgment on the complete cardinal-number reply cannot be reconstructed.

Three defects were reproduced and corrected:

- Spoken comma-separated digits were not candidates. Both spoken and numeric
  comma-separated digits now yield `124`; neither parser crosses segment newlines.
- Removing assistant fragments before concatenation joined separate caller
  answers, allowing `fourDo` to lose the final digit and produce `120`. The policy
  now uses `CallerHistory`: it preserves original deltas within caller segments
  and inserts a separator when an intervening assistant interval does not overlap
  the adjacent caller intervals. Missing timestamps use speaker changes as a
  fallback. Overlapping backchannels do not split words or numeric fragments.
  This heuristic does not establish authoritative turn completion.
- A clarification marker previously forced every subsequent uncertain reply to
  wait without a timer. New caller input now starts another bounded settle/verify
  cycle. The generic optional `ContextDecision.clarification_key` lets the app ask
  once for that new unresolved reply. Old keys remain deduplicated, omission keeps
  the original behavior, and session `max_records` bounds total attempts. A
  successful recheck starts the lookup without an unrelated wake-up event.

Regression evidence:

- Replay of the call text through the real parser/policy retains `124` after the
  progress question. Separate tests preserve overlapping backchannels and words
  or numeric IDs split across deltas, and reject numbers stitched across segments.
- Synthetic sessions using the real policy, coordinator, Jido and in-memory
  SQLite recover from a temporarily uncertain number-only reply without external
  events. A persistently unresolved reply receives one additional question; a
  later usable reply resolves. Existing stale-interpretation and correction
  timing tests remain passing.
- macOS full `mix ci`: 110 tests passed, three separately tagged stability tests
  excluded; native checks, Credo/ex_slop, ex_dna, Credence and Dialyzer passed.
- Standalone consumer: 25 tests passed on macOS and Linux. Linux coordinator,
  context-wait and original-example regression suites: 51 passed.

These regressions use scripted classification/provider responses, not historical
TypeSafe probabilities. A subsequent human browser call at 20:25 confirmed the
missing-number flow: the assistant asked for the number, “One two four” started
one lookup, the result was accepted, and the assistant captions reported order
124's correct status and tracking reference. Work status showed interpretation
settled, one completed job, and its delegation claimed. This live transcript did
not contain commas; comma handling remains covered by the offline regressions.

A separate 20:26–20:27 call successfully switched from order status to items, with
two completed jobs and accepted results. Its later follow-up (“Okay, and do you
check in my order”) triggered clarification and left interpretation unresolved,
although the assistant repeated the correct order facts. This is a remaining
interpretation issue, not resolved by this change. Neither captions nor provider
acceptance prove audible playback quality.


## Follow-up after switching from status to items

The remaining 20:26–20:27 case above is addressed by the application policy.
Previously, the most recent task contributed only `{order, operation}` even when
completed. The classifier conflated a check-in on earlier work with a new status
or items request; any sub-0.8 answer collapsed to generic uncertainty and the
policy asked for the number. Recovery then targeted that completed task, leaving
interpretation unresolved while GPT-Live could still repeat its accepted facts.

The policy now supplies lifecycle-aware recent work and caller input since the
latest task request. TypeSafe has a distinct `followup` option, and the policy
settles a confident known-order follow-up without another lookup or clarification.
Late delegations can be associated with that existing task. Ambiguous judgments
retain which selection failed, so intent ambiguity asks about the requested
information rather than repeating a known order number. The probability gate
remains 0.8 and service failures still use the unavailable-interpreter path.

Verification on September 17:

- macOS full `mix ci`: 110 tests passed, three separately tagged stability tests
  excluded; native checks, Credo/ex_slop, ex_dna, Credence and Dialyzer passed.
- Consumer regressions: 29 passed on macOS and Linux. New coverage includes
  status → items → follow-up, late delegation association, follow-up while work is
  running, and different clarification wording for intent versus order ambiguity.
- Bounded real TypeSafe replay: the reported wording selected `followup` at 0.97
  and order 124 at 0.98. “Have you checked my order?” also resolved as follow-up;
  an explicit correction selected status for order 123. An explicit refresh
  remained below the intent threshold and was left uncertain, not accepted by
  lowering the threshold. These are new judgments, not recovered historical ones.
- The real TypeSafe + Jido + in-memory SQLite session replay used three service
  calls, zero uncertain/errors, and one cache hit. It finished with exactly two
  completed jobs, both results accepted, both delegations claimed, interpretation
  settled, and no clarification context for the follow-up.

Run the service-backed replay from the standalone consumer (requires its existing
Keychain credentials; no OpenAI session or physical audio is opened):

```sh
ORDER_DESK_TYPESAFE=1 MIX_ENV=test \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/context-clarification/followup.exs
```

The replay uses complete caller fragments and a scripted provider. A subsequent
human browser call at 20:58 exercised “Check order 124”, “What items are on that
order”, and “Okay, and do you check my order”. The status and items lookups both
completed and their results were accepted. The assistant captions reported one
desk lamp, then the correct delivery status, tracking reference, and saved
instructions. Work status at 20:59:17 showed exactly two completed jobs, both
delegations claimed, and interpretation settled. No clarification was requested
and no additional lookup started for the follow-up. This confirms the reported
follow-up failure did not recur in that call; captions and work status do not
establish audible playback quality.


## Delivery refusal and receive-buffer failure diagnostics

The 21:01–21:02 human call created a reception draft for order 124, then refused
it. The order remained unchanged, but the draft stayed pending and the policy
asked for the order number three times. There was no refusal intent or backend
draft-rejection action; generic cancellation only stopped following a lookup.
The call later ended with provider `output_overflow`. The old browser projection
removed queue details, so its precise burst/drain trigger cannot be reconstructed.

The application now passes known draft state to TypeSafe and recognizes `refuse`.
It binds the refusal to the original application-owned request ID and performs
rejection in a Jido action. Store serialization and rejection records handle
refusal before a delayed creation; repeated creation cannot resurrect that draft.
Other actors' drafts are untouched, and an already-confirmed change produces an
honest already-saved result, not an undo claim. No refusal changes the order record.
The browser's existing refresh displays rejection and removes confirmation.

A real TypeSafe/Jido/SQLite replay of creation followed by “No, don't say that.
Don't save that” completed with two service calls, zero uncertain/errors, rejected
draft, blocked confirmation, unchanged order, and interpretation settled. Run
`refusal.exs` using the same standalone consumer/Keychain command as `followup.exs`.
The test database is in memory; these probes do not modify the user's saved orders.
Offline tests cover refusal during creation, repeat refusal, a late delegation,
another draft left untouched, actor isolation, and refusal after confirmation.

The provider now retains the most recent 64 numeric receive/read measurements.
Fatal receive events include that trace, queue and incoming sizes, discarded bytes,
capacity, oldest-frame age and elapsed time. Browser signaling preserves this
allowlisted evidence, including its provider source, before closing. No audio,
transcripts, credentials or arbitrary error details are added. Tests exercise trace
bounds, burst-versus-drain measurements, and end-to-end event serialization on a
fatal receive-age failure. Existing capacity/age rejection tests remain in place.

Verification: macOS `mix ci` passed (112 tests, three separately tagged stability
tests excluded; native checks, Credo/ex_slop, ex_dna, Credence and Dialyzer passed).
Consumer tests passed on macOS and Linux (32 each); the six receive-buffer and
trace tests also passed on Linux. Consumer compilation with warnings as errors
and formatting checks passed.

This corrects the missing diagnostics, not a proven historical overflow trigger.
The 500 ms receive-capacity and 750 ms age limits remain unchanged; a new overflow
will still fail explicitly and now carry evidence. No claim of glitch-free audio
or a reproduced network/scheduler trigger is made. A new human call can validate
the spoken refusal and supply a trace if the audio failure recurs.

## Refusal followed by a late transcript fragment

The 21:17 human retest rejected the draft and preserved order 124's saved
instructions, but asked for the order number afterward. The transcript delivered
`No! Don't say the`, then the assistant's `Got`, then the caller's `'that`.
The old policy treated all deltas after task admission as a fresh caller request,
so TypeSafe focused on the final fragment alone. A real TypeSafe snapshot replay
reproduced uncertainty and the three-digit-number clarification after verification.

The classifier now receives the handled caller segment alongside new deltas,
explicitly identifying the task boundary as distinct from the speech boundary.
It can recognize completion of the same refusal even across an acknowledgment.
The same snapshot replay now returned `refuse` for order 124 and no new decision,
including at the verification deadline. No confidence gate or wait was weakened.

`refusal.exs` now replays that split transcript through real TypeSafe, Jido and
in-memory SQLite, waits three seconds after the tail (longer than both recovery
deadlines), then requests items for a different order. It passed with four
classifier calls, zero uncertain/errors, a rejected draft, blocked confirmation,
unchanged order, settled interpretation, and a completed new items lookup.
The offline regression also checks late delegation association and verifies that
a subsequent genuinely missing order number still receives clarification.

Verification: all 33 consumer tests passed on macOS and Linux. Consumer formatting
and compilation with warnings as errors passed. The existing real TypeSafe
status/items/follow-up replay also completed with two accepted jobs and settled
interpretation; one transient uncertain/error judgment recovered without a
clarification. The active standalone consumer was updated with the same code.

This is a scripted transcript replay, not a new human microphone test or a
guarantee that all future classifier judgments will be correct.
