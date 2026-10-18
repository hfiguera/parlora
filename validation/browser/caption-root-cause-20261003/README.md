# Remaining GPT Live caption merge — root cause

Investigated after the manual call retained in
[the caption fix evidence](../caption-grouping-20261003/README.md#subsequent-manual-call).
Runtime under investigation: `9ca6ec8`, GPT Live 1 + Sagents 0.16.0 + `gpt-6-luna`.
No runtime changes were made in this investigation.

## Cause

The timestamp fix repairs missing transport metadata, but its grouping policy
does not identify semantic replies. `voice.js:62–64` joins any same-speaker,
unidentified interval within less than 1,000 ms of a retained group. A longer
pause inside the draft explanation splits that explanation into two rows; a
shorter pause before the verified-save announcement joins it to the draft's
last reminder. The UI has no boundary tied to the meaning of either sentence.
Changing the threshold alone trades one kind of incorrect grouping for another.

The [official OpenAI transcript documentation](https://developers.openai.com/api/docs/guides/live-conversations#transcript-deltas)
defines approximate fragment intervals and provides neither item IDs nor a
completed conversational turn event. It assigns display grouping to the client.
The OpenAI adapter retains timestamps, and signaling now forwards them. There is
no documented native reply boundary for the adapter to forward instead.

`SaveAnnouncements.paused?/1` separately waits for a one-second interval since
the last **arriving** caption for OpenAI before submitting a saved-state context
update. The browser uses the **session timeline** for grouping. These clocks
describe different things; neither the browser click nor context acknowledgment
identifies the first saved-announcement transcript fragment. The provider can
continue the draft explanation and then incorporate verified saved context.
This pause policy is a contributing limitation, not evidence of a failed save.

## Reproduction and test gap

[replay.json](replay.json) reproduces the exact shape of the failure with the
actual browser callback and explicitly synthetic intervals:

1. Main draft prompt.
2. After a 1,800 ms gap: “Saying yes won't save it.”
3. After a 200 ms gap: “Just to note, order 124 has saved the instruction…”

The resulting second row contains both sentences. Both existing live regression
guards accept it: row count increased because the draft reminder created a row,
and the regex requires `confirm` plus `has been`/`have been`/`were saved` or
`updated`. The observed row has neither `confirm` nor those verb forms. The test
therefore measures an incidental row increase rather than separation of all
draft text from the saved announcement.

Run the deterministic reproduction from the repository root:

```sh
node validation/browser/caption-root-cause-20261003/replay.cjs /tmp/NEW-caption-replay.json
```

The replay loads the callback and test harness from `9ca6ec8` through `git show`,
so it continues to reproduce the historical defect after the current code is fixed.

The previous passing live test also contains a 1,490 ms packet-arrival gap while
the corresponding session-timeline gap is only 200 ms, within the draft's words
“the package.” This directly illustrates why arrival quiet cannot establish a
completed sentence or reply. See the original
[timestamped case](../caption-grouping-20261003/live/20-browser-confirmation-r1.json).

## Live diagnostic experiment and limits

A single isolated GPT Live/Sagents probe confirmed the browser draft as soon as
the model mentioned Confirm, while it was still delivering the explanation.
The exact [scenario override](live-preload.cjs) is retained separately from the
canonical runner hashes; [source hashes](source-sha256.json) identify both.

The model continued with “Saying yes here doesn't save it.” Its next announcement
began 1,600 ms later on the session timeline, so this attempt **did not reproduce
the merge**. The save occurred once, the stored text matched, and cleanup reported
zero sessions. The diagnostic runner nevertheless marked the attempt **failed**:
its narrow predicate expected `saved` or `updated`, whereas the model said
“the confirmed update” and reported the correct instructions. That timeout is
retained unchanged in [the report](live-report.json) and [log](live-run.log).
[Extracted observations](live-observations.json) retain the actual fragment
intervals, confirmation checkpoint, final captions and database observations.
No retry replaced this outcome.

The original human call retained final rows and diagnostic events, but not its
individual transcript intervals. Its exact numerical gaps cannot be recovered.
The deterministic replay proves the implementation flaw; the fresh live probe
illustrates a successful timing case, not proof of the original call's timings.

## Recommended fix scope

Use explicit display boundaries for unsegmented captions, such as completed
sentence boundaries, with timestamps retained for ordering and overlap. Native
provider segment IDs should remain authoritative for providers that supply them.
Do not infer saved-state transitions from silence duration, invent provider reply
IDs or change backend/save behavior to repair captions. Add coverage for the
trailing draft reminder and contiguous saved announcement, including both
sentences arriving in a single delta, exact fragment preservation and varied
confirmation timing. Replace the current row-count/phrase checks with assertions
that detect this actual failure shape. This investigation does not implement
those changes.

The subsequent [sentence grouping fix](../caption-sentences-20261003/README.md)
implements the recommended display change and retains its own verification.
