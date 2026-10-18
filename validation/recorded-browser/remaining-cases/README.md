# Delivery correction and interruption/reconnect — September 17, 2026

Verified through the Codex internal browser at `http://127.0.0.1:4001` using
recorded caller speech, real WebRTC/GPT-Live/TypeSafe/Jido, and the isolated
`/tmp/parlora-correction-disconnect-20260917.sqlite3` database. The normal
`localhost:4000` application's records were not edited.

Additional recordings in `scripts/recorded_audio.sh` reproduce the user's phrases:

- Reception: “For order one hundred twenty four, leave the package at reception.”
- Correction: “Actually, leave it with the neighbor.”
- Interruption: “Wait! What items are in order one hundred twenty four?”

Generate all six clips again after updating the consumer. These controls are
available only with the existing development opt-in. The fixed server allowlist
now includes `package.wav`, `correct.wav`, and `interrupt.wav`.

## 1. Correct delivery instructions: pass

The call created a pending draft for order 124 with `leave the package at reception`.
After the correction, a second pending draft appeared with exactly
`leave it with the neighbor`. Both jobs completed and their results were accepted.
The test selected the proposal by its displayed text, rejected only the reception
proposal, and explicitly confirmed only the neighbor proposal through the browser.

SQLite verified:

- Reception proposal: `rejected`.
- Neighbor proposal: `applied`.
- Order 124: `leave it with the neighbor`, version 2.
- Exactly one saved change; no other order changed.

Evidence: [captions](correction-captions.txt) and [events](correction-events.txt).

## 2. Interrupt and disconnect: partial pass

A separate unsaved draft for order 123 was created with the browser editor solely
to verify pending-draft persistence. The interruption call started in a fresh
session. No greeting appeared within the initial 20-second wait, so an items
request for order 123 elicited assistant speech instead.

At 21:49:13.357 local time, the assistant caption had just reached **“I'll check”**
and the browser audio element was playing (`paused=false`). The test clicked
**Play interruption** immediately, sending the order-124 phrase through the
outgoing audio track while the assistant response was underway. This is timing
and playback-element evidence, not a human assessment of acoustic barge-in.

The user caption captured order 124, and the assistant acknowledged the correction,
but the application requested the three-digit order number again. Interpretation
became unresolved with the new delegation pending. Therefore the first interruption
was **not** a clean conversational pass. Its underlying classification failure is
not diagnosed by this test. See [initial captions](interruption-first-captions.txt)
and [initial events](interruption-first-events.txt).

Repeating the same phrase answered that clarification and started the order-124
job. The test backend used the existing `:lookup_delays` option with an eight-second
delay for order 124, making it possible to observe work in progress. At 21:50:32,
Work status showed job `JddRiXfkg3s5PeNxDPLU3OjT` submitted with `started_at_us`,
about 462 ms into execution. The test immediately disconnected; it did not merely
disconnect after completion. [Evidence](disconnect-evidence.json),
[events](disconnect-events.txt).

The application subsequently reported zero active sessions. Reconnect created
session `S9X7Wcj-9kMZNvy4wo5MrKzG`, distinct from the interrupted
`--0MP1x1TR60ovHpts4QjTnG`, with empty jobs and delegations and interpretation
settled. Saved neighbor instructions and the pending order-123 draft remained.
A fresh items request for order 124 completed in that new session, delivered an
accepted result, and the assistant answered **one desk lamp**. No old running job
appeared in the new session. [Fresh status](reconnect-status.json),
[completed request](reconnect-final-status.json), [captions](reconnect-captions.txt).

**Runtime disconnect/reconnect and persistence passed.** However, the UI retains
prior-call captions and can concatenate a new greeting with an old assistant
caption. That display is not evidence that session context was inherited, but it
is a separate UI rough edge; the page did not visually reset the conversation.
The caption-reset follow-up below addresses this display issue.

All test calls were explicitly disconnected. No browser console warnings/errors
or provider output-overflow event were observed. Normal startup capture discards
and playback-starvation observations exist; these are not a verdict on audible
quality. Human microphone behavior and physical Linux audio remain outside this
synthetic-input test.

## Caption-reset follow-up: pass

The shared microphone/recorded-input connection path now clears both the caption
array and its rendered transcript when starting a new connection attempt. The
finished call remains readable after disconnect, until the next connection starts.

Verified with two live recorded-input calls in the same browser page, without a
reload between calls. The first call answered the order-123 items request. Its
captions remained after disconnect, then immediately changed to “Your new
conversation will appear here.” on reconnect. The second call's greeting appeared
as a new assistant caption, without the old caller text or answer. Saved neighbor
instructions and the existing draft list were identical before and after reconnect;
the unsaved order-123 draft had already expired before this test. This checks
existing draft retention, not extension of the draft expiry deadline.
The second call also answered a fresh items request correctly. Both calls were
disconnected. See [before/after transcripts and retained state](caption-reset.json).

JavaScript syntax validation and `git diff --check` passed. The maintained consumer
fixture and standalone consumer use the same updated script.

## Reproduction and checks

Use the recorded-input setup from [APPLICATION.md](../../../examples/order_desk/APPLICATION.md).
For a deterministic running-job window in an isolated macOS process:

```sh
ORDER_DESK_RECORDED_INPUT=1 ORDER_DESK_TYPESAFE=1 \
ORDER_DESK_DATABASE=/tmp/order-desk-correction-test.sqlite3 \
PORT=4001 BROWSER_ORIGIN=http://127.0.0.1:4001 \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run -e \
  'Application.put_env(:order_desk, :lookup_delays, %{"124" => 8_000}); OrderDesk.BrowserServer.run()'
```

The backend delay is test configuration, not a changed runtime default. The
currently running isolated test server uses that delay. All six clips share the
existing playback bounds and cleanup path. The three recorded-input route/config
tests passed on macOS and Linux; the three Node lifecycle tests passed. The prior
full 36-test suites remain the baseline; no library or business-policy code changed
for these two additional scenarios.
