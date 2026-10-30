# Phonic result-reply coordination — 2026-10-29

The reported extra “Order 124” caption prompted a narrower check than the earlier
workflow-completion assertions. A retained live-service trace showed the adapter
requesting a second reply after an automatic turn had already announced the
verified status. A standalone adapter replay reproduced that request without
OrderDesk loaded. The original manual call did not retain provider wire messages,
so its exact fragment and physical audibility cannot be reconstructed conclusively.

## Cause and change

Previously, `:speakable` context was transmitted immediately while also setting
`continuation?: true`. If Phonic's automatic response used that context, the
continuation remained queued and requested another response after speech drained.
Completed late associations could also queue a redundant continuation during an
existing result reply. This was a Phonic adapter scheduling issue; the OrderDesk
caption renderer simply displayed provider fragments.

The adapter now keeps speakable updates in a bounded local queue until caller
speech, automatic/current generation, and received audio have settled. It then
publishes the context and requests one explicit result reply. Phonic's
`forbid_speech_after_tool_call: true` prevents an automatic post-tool answer from
competing with that explicit reply. Tools remain async, `wait_for_response` stays
false, and caller corrections/new delegations remain possible. Pre-tool speech
is optional. The adapter does not match spoken wording against backend summaries.

A completed association for a covered result closes without resubmitting the
facts or scheduling another announcement. A reply that yields to a tool call
before producing output can resume once when that call is associated, preserving
the earlier stall fix. New caller turns can request the same result again.

Queued updates retain command IDs; `context_submitted` and acknowledgment timers
start only after socket transmission. Newer queued task revisions replace older
ones. Cancellation removes queued correlated results; expired calls fall back to
new context. Admission is bounded by `max_records`, closure rejects retained
commands, and the optional per-reply context hint is bounded to 16,000 bytes.

Only the Phonic adapter/protocol change at runtime. OrderDesk policy, JEV model,
thresholds, caption rendering, other provider adapters, and shared session logic
are unchanged.

## Proof

From the repository root:

```sh
# Expected: six failures with the adapter/protocol from 6d174ad, in this VM only.
MIX_ENV=test mix run validation/interpretation-scheduling/replay_phonic_reply_before.exs

# Expected: the same six cases pass with current code.
mix test test/phonic_adapter_test.exs --only reply_coordination --warnings-as-errors

# Includes existing late-association and tool-only-turn stall regressions.
mix test test/phonic_adapter_test.exs test/phonic_protocol_test.exs \
  test/phonic_session_test.exs --warnings-as-errors
```

The six new cases fail against the pre-fix implementation and pass with the
change. The focused suite passes **40 tests**. It covers holding results through
an automatic acknowledgment, one subsequent result reply even with paraphrasing,
quiet closure of duplicate associations, queued revision replacement, cancellation,
explicitly configured early delegation, and a started response that yields to a
tool before producing output without a speech-end event. Additional checks cover queue
capacity, closure, queued tool expiry, new caller retries, and tool-only recovery.

The full library suite passed **595 checks** (six properties and 589 tests; three
hardware/live/stability cases excluded). OrderDesk passed **248 tests**, and its
browser JavaScript tests passed **3/3**.

## Live workflow and independent wire audit

The longer OrderDesk fixture now supports `ORDER_DESK_ASSERT_SINGLE_REPLY=1`.
Its thirteenth assertion rejects a new assistant response after a completed result
answer unless fresh application context requested another response. It observes
speech starts, so even an interrupted fragment can fail the assertion. The prior
12 assertions still check corrections, stale-result suppression, six backend
operations without duplicates, draft refusal, and exactly one explicit save.

From `examples/order_desk`, after refreshing the vendored library:

```sh
PARLORA_PROVIDER=phonic ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
ORDER_DESK_ASSERT_SINGLE_REPLY=1 \
  python3 scripts/with_keychain.py mix run --no-compile \
  ../../validation/interpretation-scheduling/trace_live.exs \
  /tmp/orderdesk-scheduling-clips /tmp/phonic-replies.json
```

An independent audit of the actual provider control messages checks for a new
`generate_reply` after a completed status/items answer with no intervening caller
input or submitted application context. Its fact anchors are specific to these
synthetic fixtures; they are not production matching logic.

```sh
python3 validation/interpretation-scheduling/audit_phonic_replies.py \
  /tmp/phonic-replies.json.trace.json
```

The auditor detects the old live trace's extra request at **32.528 seconds**.
Both final-code Phonic runs pass **13/13 assertions**, with two completed
status/items answers each and zero such requests. Three earlier strict iterations
also passed; the failed empty-yield attempt is retained in the summary. Gemini, OpenAI, and
Grok also completed the original 12-assertion workflow with unchanged adapters.
See [all attempt summaries](reply-coordination-summary.json) for iterations,
counts, and evidence limits.

A verification repeat also exposed an empty started response that yielded to a
tool without sending a speech-end event. Its association stayed queued behind
the abandoned speaking state. A sixth regression reproduces it; the adapter now
retires that empty owned generation on delegation. The failed attempt remains
in the summary.

The preliminary Phonic run completed but repeated the status in response to a
**fresh OrderDesk clarification update**. That is distinct from a leftover adapter
continuation. It remains recorded, not relabeled as a duplicate-scheduling pass.
These checks establish the scheduling fix, not a guarantee that a model can never
repeat itself or mishandle a new prompt. Generated audio and captions also do not
establish physical playback.

The earlier `replay_phonic_before.exs` keeps its original three-failure evidence
stable by loading its historical test source from `6d174ad`; it does not silently
apply that historical count to the expanded current suite.
