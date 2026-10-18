# First four conversation cases — September 17, 2026

Follow-up: the two unnecessary-clarification failures below were investigated and
fixed; see [diagnosis and fix verification](../clarification-root-cause/FIX-RESULTS.md).

Ran four separate calls in the Codex internal browser against the isolated
`http://127.0.0.1:4001` app using synthetic caller speech and the real
WebRTC → GPT-Live → TypeSafe → Jido path. No business-policy or library code was
changed for this run. These are individual observations, not a reliability rate.

The test used `/tmp/parlora-correction-disconnect-20260917.sqlite3`, retaining the
previous test's saved neighbor instructions on order 124, version 2. The normal
`localhost:4000` app's records were not edited. The existing test-server
`:lookup_delays` configuration added eight seconds to order-124 backend jobs;
order-123 jobs were not artificially delayed.

## Results

| Case | Result | Evidence |
| --- | --- | --- |
| Correct 123 → 124 → 123 | Partial pass | Three lookup revisions completed and were accepted. The final answer correctly concerned order 123, shipped and expected Friday. A subsequent application clarification left interpretation `unresolved`, despite the completed answer. |
| Omit the number, then say “One two four” | Pass | The assistant asked for the number, then reported order 124 out for delivery. One job completed with delivery `accepted`, its delegation was claimed, and interpretation was `settled`. |
| Check 124, then ask for its items | Partial pass | The initial status request started no job and unnecessarily asked which operation was wanted. The follow-up correctly resolved “that order” to 124, completed an items lookup, and answered one desk lamp. Final interpretation was `settled`; both delegations were claimed. The expected status answer was missing. |
| Create a reception draft, then refuse | Pass for current implementation | Waited for the exact draft to appear, then said “No, don't save that.” The current app automatically marked that draft `rejected`; the record remained visible. Both jobs completed, results were accepted, and interpretation was `settled`. Saved instructions and order versions did not change. |

Case 4's older expectation that spoken refusal leaves a pending draft for manual
rejection is stale. A recognized refusal now rejects the current call's associated
draft. No **Confirm** or **Reject draft** button was clicked in this case. SQLite
confirmed exactly one new proposal, `leave it at reception` for order 124, rejected;
the entire orders and changes tables matched their pre-test values.

The case-1 and case-3 clarification issues remain open. This run establishes the
symptoms; it does not establish their root causes or whether they share a cause.

## Evidence

- Case 1: [captions](case1-captions.txt), [events and work status](case1-events.txt).
- Case 2: [captions](case2-captions.txt), [events and work status](case2-events.txt).
- Case 3: [captions](case3-captions.txt), [events and work status](case3-events.txt).
- Case 4: [captions](case4-captions.txt), [events and work status](case4-events.txt).
- [Intermediate clarification/draft displays and before/after page state](states.json).
- SQLite [before](database-before.json) and [after](database-after.json).

## Input and reproduction

Exact spoken text is in [phrases.json](phrases.json). Generated each phrase using
macOS `say -v Samantha -r 165 --file-format=WAVE --data-format=LEI16@24000`.
The fixed development-only WAV slots were temporarily populated as follows before
connecting each call; the page's button labels were unchanged:

| Case | Play draft request (`draft.wav`) | Play refusal (`refuse.wav`) | Play items request (`items.wav`) |
| --- | --- | --- | --- |
| 1 | `check123` | `correct124` | `back123` |
| 2 | `missing` | `number124` | unused |
| 3 | `check124` | `referential_items` | unused |
| 4 | `draft` | `refuse` | unused |

These names refer to keys in the phrase file, not the controls' usual meanings.
Back up the original WAV files before substituting them. The browser loads clips
when connecting, so substitutions must precede connection. Restore the originals
after testing; this run restored and byte-verified all original clips.

Each case began after a fresh connection and greeting. Case 1 sent corrections
after acknowledgment of the preceding request; earlier results could complete
before a correction, as allowed by the scenario. Case 2 waited for the explicit
number question. Case 3 waited for the first response (which was the unexpected
operation question) before asking for items. Case 4 waited for a visible pending
draft before refusing it. Final **Work status** snapshots were captured before
disconnecting each call.

All four calls were disconnected; `/health` returned zero active sessions.
No browser console warnings/errors or provider output-overflow events were
observed. Capture-overflow/startup-discard and playback-starvation counters were
present. These tests do not assess audible smoothness, human microphone behavior,
or physical Linux audio.
