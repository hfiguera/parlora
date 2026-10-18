# Streamed request fixes

The three failure paths from [the investigation](../root-causes/README.md) are
addressed without changing the classifier confidence threshold or live acceptance
assertions. Initial failed runs and diagnostic replays remain preserved; those
replays assert the old failure and are not post-fix acceptance tests.

## Changes

- Reconstruct only supported unfinished number prefixes followed by an incomplete
  leading suffix across caller segments. Preserve following operation text, so
  “one hundred twenty” / “four, change the delivery instructions…” offers 124.
  Complete replacement IDs, explicit new requests and conflicting numbers remain
  separate. Raw transcript history is retained unchanged.
- Retain request text on the application task. A strict continuation of an already
  admitted refusal sentence is recognized as no additional work. In particular,
  the trailing “instructions” in “No, don't save that. Keep the original
  instructions” cannot reopen the refusal as an uncertain new operation. New or
  conflicting requests still use normal classification and clarification.
- Extend `:start_task` with an existing-task/revision target for application-owned
  follow-ups without a provider delegation. This creates a separate task with a
  nil delegation ID. Missing/stale anchors and simultaneous delegation/task
  targets are rejected. Existing snapshot, batch, job and record limits apply.
  The consumer associates a late matching delegation without executing another
  job. Initial work still requires a real provider delegation.

The first two changes belong to the consumer application. The small admission
extension is in Parlora, with its contract updated in the brief and public
interfaces. Standalone consumer source and its vendored library were synchronized
for testing. No audio buffering or pacing code changed.

## Automated validation

- macOS and Linux `mix ci`: **186 passed, 3 excluded**, native Rust checks,
  Credo/ex_slop, ex_dna, Credence and Dialyzer passed.
- macOS consumer: **125 passed**.
- Linux consumer: **125 passed** on the final unchanged run. The first run, while
  library CI was also running, failed the existing greeting test's 100 ms
  subscriber-start assertion. Its initial failure log is retained. The greeting
  tests passed in isolation and the full suite then passed, with no assertion,
  timeout or production greeting changes. Scheduling contention is a plausible
  explanation, not a proven diagnosis of that transient failure.
- New regressions exercise the exact split number plus operation, unrelated
  number controls, an uncertain refusal suffix, a subsequent genuinely unknown
  target, admission without delegation, and late/duplicate delegation handling.
- A library session test checks stale/missing/ambiguous admission targets,
  separate task identity, and nil delegation on the delivered result.

The existing status-after-items regression now requires work to start before
provider delegation and asserts that the later delegation does not duplicate it.
Its old assertion required the silent delay being fixed. Live suite assertions
are unchanged.

## Live validation and retained intermediate results

- Browser: **6/6 passed** after the continuation correction; see
  [final report](browser-final.json).
- Twilio: **6/6 passed**; see [report](twilio.json) and
  [routing cleanup](twilio-cleanup.json).
- Telnyx: **6/6 passed** on the completed patch; see
  [final report](telnyx-final.json) and [routing cleanup](telnyx-final-cleanup.json).

The first browser retest passed the original failing draft case, but its
interruption case exposed another split: “one hundred” / “twenty-four”. The
parser recognized the one-digit suffix but not the two-digit cardinal. The
correction now supports that form too, with an exact regression. The first run
and its failure are retained in `browser-first.json` and
`browser-number-split-failure.json`.

An existing parser test caught an intermediate regression: a bare trailing “and”
was parsed as zero after stripping the conjunction. The implementation now
rejects the empty remainder. The original assertion is unchanged; the final
macOS/Linux suites and 20 focused parser/streaming tests passed.

The first Telnyx retest stopped during the status request in case 3: the call
produced a greeting but no caller transcript or delegation, so it never reached
the items follow-up. No interpretation/job ran. This is not evidence of the
previous task-admission bug recurring. The cause of that missing input is not
established; the failed run and routing cleanup are preserved in
`telnyx-first.json`, `telnyx-first-no-input.json`, and
`telnyx-first-cleanup.json`.

The browser successful run includes the two-digit cardinal correction. Twilio's
successful run preceded that additional parser change; the final parser changes
are covered by the macOS/Linux consumer suites and the subsequent Telnyx run.
The browser run preceded the final empty-conjunction guard, whose unchanged
regression test passes in those final suites. No successful report replaces an
intermediate failure or claims identical code where the tested versions differ.

These live checks assess conversation behavior, not perceived audio quality.
The earlier audio assessment remains separate.

Both telephone providers had their original routing restored and verified. All
test call legs completed and temporary caller applications were deleted. The
regular development server was already stopped and was not restarted.
