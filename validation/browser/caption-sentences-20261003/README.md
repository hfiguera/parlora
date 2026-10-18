# GPT Live sentence caption fix — October 3, 2026

This addresses the [remaining manual-call merge](../caption-root-cause-20261003/README.md):
“Saying yes won't save it” shared a row with the verified-save announcement.

The renderer now displays each English sentence in an unidentified timed group
separately, using `Intl.Segmenter`. It re-segments accumulated text when fragments
arrive, including two sentences in one delta. Whitespace, quotes, split words and
decimal versions remain unchanged. Session intervals still organize groups and
overlapping/late fragments; native reply IDs preserve their existing grouping.
The display is limited to 100 rows. Sentence boundaries are a browser display
policy, not provider reply IDs, playback completion or business-work boundaries.
Abbreviation handling follows the browser's sentence segmenter.

The live confirmation check now verifies one sentence per unidentified row and
exact reconstruction of the assistant transcript, rather than incidental row
count growth and a narrow phrase regex. Unit coverage explicitly rejects the
manual reminder/save wording and accepts alternative announcement wording.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| JavaScript regression suites | 35 passed, including 16 browser caption cases | [log](tests.log) |
| Desktop/mobile rendering | 1280/375 px passed; exact reminder/save text in separate rows, no overflow or page errors | [report](layout/report.json), [desktop](layout/desktop.png), [mobile](layout/mobile.png) |
| UI detector | No findings | [result](design-check.json) |
| Normal browser confirmation | One scheduled live attempt passed | [report](normal/report.json), [case](normal/20-browser-confirmation-r1.json) |
| Early browser confirmation | One scheduled live attempt passed | [report](early/report.json), [case](early/20-browser-confirmation-r1.json) |

Both live checks used GPT Live 1, Sagents 0.16.0, `gpt-6-luna` (no reasoning),
and `jev-1.13.0` interpretation. The normal check retained 65 assistant fragments;
the early check retained 55. Each saved the exact draft once, with zero active
sessions after cleanup. In the early case, the final two assistant rows were:

1. “Saying yes won't save it.”
2. “Saved it for order 124: left in my front door.”

The early experiment clicked Confirm as soon as the assistant mentioned it,
before its trailing reminder. The exact [scenario override](early-preload.cjs)
is retained separately from the canonical runner metadata. Its save predicate
accepts `saved`, `updated`, `confirmed update` and `now has` with the expected
destination, avoiding the diagnostic wording timeout in the earlier investigation.
These are two different scheduled cases, not retries; neither failed.

The previous root-cause probe's failed timeout remains unchanged in its own
evidence directory. The historical replay now loads the defective callback from
`9ca6ec8` via `git show` so the original issue remains reproducible after this fix.

The live checks used synthetic speech and caption/database observations; no human
listening assessment is claimed. Layout screenshots are synthetic fixtures using
the canonical HTML, CSS and actual caption callback. No Elixir, backend, provider
adapter or save-announcement behavior changed, so the previously passing Elixir
and packaged-consumer suites were not repeated for this JavaScript-only fix.

Tests ran against `9ca6ec8` plus the uncommitted fix. [Source hashes](source-sha256.json)
identify the final code and the installed manual consumer asset. The normal
runner started before the provenance-only addition of `priv/browser` hashes;
its served caption asset is recorded in this manifest. The early runner's report
also includes browser asset hashes directly. Raw audio, SQLite databases and
copied runner/consumer sources remain outside the repository under `/tmp`.

The idle manual server at `http://localhost:4300/` now serves the updated asset,
and its browser tab was reloaded. The existing manual database remains at order
124 version 4; these automated checks used isolated databases.
