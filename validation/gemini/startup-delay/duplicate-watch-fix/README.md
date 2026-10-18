# Pending reply survives duplicate tool calls

The 19:58 test call submitted the corrected order result at 19:58:29.321. Gemini
then issued another call with a different ID. Parlora associated it with existing
work and sent a `SILENT` function response at 19:58:29.835. No extra backend job
ran, but admission of the new call had cleared the response deadline. The reply
arrived at 19:58:42.517 (13.196 seconds after result submission) without a warning.

The fix separates tool activity from a reply to the caller. Incoming calls retain
an existing response deadline and displayed warning. `SILENT` completion also
retains that state, and creates no timer when no response was outstanding. Other
function responses start a watch when none exists. Assistant captions/audio and
connection cleanup still clear it. Tool correlation, application deduplication,
response scheduling, and business execution are unchanged.

Local WebSocket regression tests reproduce the ordering: original call, result,
new call ID, silent association, original deadline, another duplicate after the
warning, and late assistant reply. They check that one warning appears, subsequent
duplicates cannot clear it, the late reply succeeds without closing the provider,
and a silent response after already completed speech creates no new expectation.
Additional coverage checks non-silent resolution without a pre-existing watch.

The monitor reports lack of an assistant reply. Legitimate backend work may still
be running when it fires. This patch does not identify or repair Google's internal
reason for the delayed audio. No live request or human audio recording was needed
to reproduce the local timer defect.

Verification: macOS and Linux each passed `mix ci` with 288 library tests/properties
(three stability tests excluded), native tests, formatting, Credo, duplicate
checks, Credence, and Dialyzer. OrderDesk passed all 177 application tests on both
platforms. The focused Gemini WebSocket suite passed all 15 tests. The server was
restarted while idle with matching workspace sources and the existing test database;
no human recording was enabled.
