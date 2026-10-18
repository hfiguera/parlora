# GPT Live caption grouping fix — October 3, 2026

The browser previously merged the draft confirmation prompt and the later saved
announcement. GPT Live transcript fragments already carried `start_ms` and
`end_ms` in Parlora's protocol adapter, but browser signaling dropped both fields.
The UI grouped successive assistant fragments with absent reply IDs into one row.
Clicking Confirm creates no caller caption to interrupt that grouping. This
predates the Sagents 0.16.0 upgrade and can occur with any backend using GPT Live.

Signaling now retains those session timestamps. For fragments without native
reply IDs, a gap of at least one second starts a new display group. Overlapping
speakers and late fragments update their own retained group. Native IDs still
take precedence, and fragments retain exact whitespace, split words and numbers.
The one-second threshold is a UI policy, not an authoritative conversational turn
boundary; it does not control audio, tool dispatch or database writes. The
[provider guide](https://developers.openai.com/api/docs/guides/live-conversations#transcript-deltas)
describes the timestamps and absence of item IDs/turn completion events.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Root `mix ci` | 362 tests/properties, 3 excluded; static checks and Dialyzer passed | [log](ci.log) |
| Protocol/signaling focused tests | 21 passed | [log](focused-tests.log) |
| Browser, task-pilot and release JavaScript tests | 29 passed, including 11 caption regressions | [log](node-tests.log) |
| Fresh packaged Sagents consumer | 199 tests; test/prod compilation and production release passed | [log](consumer.log) |
| Offline release checks | All four stages passed | [report](release/report.md) |
| Desktop/mobile rendering | Separate rows, no horizontal overflow or page errors at 1280/375 px | [report](layout/report.json), [desktop](layout/desktop.png), [mobile](layout/mobile.png) |
| Live browser confirmation | One scheduled attempt passed; no retries | [report](live/report.json), [case evidence](live/20-browser-confirmation-r1.json) |
| Impeccable UI detector | No findings | [result](design-check.json) |

The live test used GPT Live 1 with Sagents 0.16.0 and `gpt-6-luna` (no reasoning),
plus the `jev-1.13.0` TypeSafe interpreter. All 56 assistant caption fragments
contained numeric session timestamps. The browser showed these separate rows:

1. Greeting.
2. Acknowledgement of the delivery-instruction request.
3. Draft text and request to press Confirm.
4. “Update saved for order one twenty four: leave the package at reception.”

The voice request created a pending draft without saving. Explicit browser
confirmation saved the exact draft once; the other orders stayed unchanged.
Cleanup reported zero active sessions. These checks use synthetic speech and
caption/diagnostic observations; they do not establish human listening quality.
The desktop/mobile screenshots use synthetic fragments in the canonical page,
not the live call.

The first layout probe passed desktop but failed mobile because its test script
redeclared a global lexical binding after `setContent`. That harness failure is
retained in [the initial report](layout-initial/report.json) and
[log](layout-initial/run.log). Isolating the callback fixture in an IIFE fixed the
harness, and the final desktop/mobile probe passed. No live failures were replaced.

Tests ran against `edb8f90` plus this uncommitted fix. The live/release reports
record canonical and consumer source hashes; [source-sha256.json](source-sha256.json)
records the final relevant source files. Raw audio, SQLite databases and copied
consumer source remain under `/tmp`, outside the retained evidence.

The manual server at `http://localhost:4300/` was restarted from the verified
consumer with GPT Live 1 + Sagents and the existing manual database; its browser
tab was reloaded.

## Subsequent manual call

The user made a call at 20:39–20:40 MDT. [Observed captions and events](manual-call.json)
show the order correction from 123 to 124 succeeding: the original result was
marked stale, while the corrected result was accepted. All five backend requests
completed; the four current deliveries were accepted. Status, item and existing
instruction lookups returned the expected order 124 facts. The new text, `left in
my front door`, was saved once as version 4; other orders retained their versions.
The call disconnected and `/health` reported zero active sessions. Interpretation
diagnostics reported 36 calls, one cache hit and 11 failures/uncertain judgments;
the aggregate does not establish their individual causes.

The main draft prompt and saved announcement now occupy separate rows. However,
the draft's final reminder, “Saying yes won't save it,” shares the next row with
the saved announcement. [Screenshot](manual-captions.jpg). This is a remaining
caption grouping edge case, so the manual result does not establish complete
separation of every draft fragment. No new fix was made during this call review.
The user has not yet supplied a listening-quality assessment of this call.
