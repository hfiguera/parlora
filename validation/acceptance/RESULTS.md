# Acceptance runner validation — September 17, 2026

## Automated checks

- macOS: 6/6 deterministic acceptance scenarios; full consumer suite **51 passed**.
- Linux: 6/6 deterministic acceptance scenarios; full consumer suite **51 passed**.
- Node runner tests: **3 passed** on macOS and Linux, covering offline credential
  isolation, nonzero failure/no retry, and prompt failure reporting for a closed
  session with provider output overflow.
- Consumer formatting and compilation with warnings as errors passed.
- Parlora macOS `mix ci` passed: **113 tests**, three separately tagged tests
  excluded, native checks, Credo/ex_slop, ex_dna, Credence, and Dialyzer.
- CI now runs deterministic acceptance and uploads its reports on both platforms.
  Hosted CI itself has not been run from this workspace.

## Live browser run: 5/6 passed

[Recorded report](results/report.json), [per-case summary](results/live.json).
The run used isolated SQLite data, Chrome with synthetic outgoing speech, real
WebRTC/GPT-Live/TypeSafe/Jido, and the existing pinned development toolchain.

| Case | Result |
| --- | --- |
| Repeated 123 → 124 → 123 corrections | Pass; three jobs, final current 123 result accepted |
| Missing number, then “One two four” | Pass; no speculative lookup, 124 result accepted |
| Status then items | Pass; separate work and desk-lamp answer |
| Draft then refusal | Pass; exact draft rejected and saved record unchanged |
| Correct draft, reject old, confirm new | Pass; two exact drafts, one explicitly confirmed database version increase |
| Interrupt and disconnect | **Failed before the intended disconnect**; provider output overflow closed the call |

The sixth case was not retried to obtain a pass. Its first order-123 items job
started, but the interruption was not transcribed and no corrected order-124 job
started. The provider emitted `output_overflow`, then `failed`, then `closed`.
At overflow: **20,160 queued bytes + 4,800 incoming bytes exceeded 24,000 bytes**;
oldest queued audio was about **79 ms** old. This records the observed failure,
not a complete root-cause diagnosis. See [case evidence](results/6-interrupt-disconnect.json).
Reconnection and persistence assertions were not reached in this live run.

The runner originally reported this as a timeout waiting for the corrected job.
It now checks closed/closing state and includes `provider output_overflow` in the
failure immediately. The captured failure was preserved unchanged; a separate
regression tests the improved diagnostic. No audio bounds were relaxed and no
production library/application behavior was changed.

## Harness qualification notes

The initial live attempt passed case 1, then exposed an observer bug: a public
snapshot request can return `{:error, :closed}` while a session is closing. The
test observer now retains the last valid snapshot and marks the session closed.
The subsequent full live run above exercised cleanup across cases and found the
actual provider failure. An earlier attempt also stopped before live calls because
Playwright dependencies were absent; setup now reports the required npm command.

The explicit no-unexpected-clarification and exact-three-corrections-job checks
were added while the retained live run was underway. They were re-evaluated against
its captured evidence and passed; [additional assertions](results/additional-assertions.json).
The final runner also requires the assistant caption to follow the latest caller
caption when selecting the interruption point. The retained sixth-case checkpoint
already meets that condition. Its remaining failure is not relabeled as a pass.

Reports retained here contain only synthetic demo conversation/data. Full local
reports additionally contain screenshots, generated WAV fixtures, and isolated
databases. The private report directory is recorded in `results/report.json`.
Test servers and browser processes were closed. The user's existing server and
its database were not modified by the acceptance run.

This suite verifies observable application state and delivery acknowledgements.
It does not establish human-perceived audio quality, physical Linux audio, or
public-network behavior. The newly captured provider overflow remains a separate
runtime finding to investigate.

Follow-up: the [root-cause investigation](../../docs/acceptance-overflow-investigation.md)
replayed the exact failure offline. Six 100 ms chunks arrived within 79.201 ms;
normal paced draining removed 80 ms, leaving 520 ms for the 500 ms receive
budget. The original live result remains failed; this diagnosis does not change
runtime behavior or claim the interruption scenario passed.

## After the receive-capacity correction

The receive default is now 33,600 bytes / 700 ms, with the same 750 ms age
deadline and normal playback pacing. The original evidence above is unchanged.

- macOS and Linux `mix ci`: **114 passed**, three tagged tests excluded; native
  checks, Credo/ex_slop, ex_dna, Credence, and Dialyzer passed.
- Consumer tests: **51 passed on each OS**. Offline acceptance: **6/6 passed**.
- Node runner regression checks: **3 passed**.
- The exact captured burst rejects with the old limit, passes with the new
  default, and drains all bytes in order at playback speed before expiry.
- Full-budget clear/suppress/resume and capacity/age boundaries passed.

The subsequent [live report](results-after-overflow-fix/report.json) remains
**5/6 overall**, with a different outcome:

| Case | Result after correction |
| --- | --- |
| Repeated corrections | Failed before the first lookup: “Check order one-twenty three” prompted clarification; interpretation remained unresolved |
| Missing number | Pass |
| Different questions | Pass |
| Draft refusal | Pass |
| Draft correction | Pass |
| Interrupt and disconnect | **Pass**, including corrected running job, disconnect, fresh session, retained saved/pending records, and fresh desk-lamp result |

There were **zero recorded provider audio discontinuities** across this run
([verification](results-after-overflow-fix/verification.json)). The original
interruption overflow did not recur. This does not guarantee glitch-free audio;
channel startup capture discards and playback-starvation observations still
appear separately in the evidence.

The first-case interpretation failure was retained without retry, and the runner
correctly returned nonzero. It is separate from the fixed receive-capacity failure
and remains a follow-up for the example application's interpretation path. No
acceptance assertions were relaxed. The isolated server/browser were closed and
the user's existing servers and databases were left running unchanged.

The remaining first-case failure is now [diagnosed](../../docs/order-number-investigation.md):
the application's spoken-ID parser sums “one-twenty three” to 24, discards it as
not three digits, and offers TypeSafe only `unknown`. An offline replay reproduces
the resulting clarification path; the parser has not yet been changed.

## After the spoken-ID correction

The example application's parser now handles “one-twenty three” and other bounded
abbreviated IDs, including settling and late completion of streaming prefixes.
The [implementation notes](../../docs/order-number-investigation.md#implemented-fix-and-validation)
describe the grammar and regression evidence. The previous paragraphs retain
the diagnosis and outcomes before this correction.

- Final application tests: **56/56 passed on macOS and Linux**.
- Formatting and compilation with warnings as errors passed.
- Deterministic acceptance: **6/6 passed**.
- Full live browser acceptance: **6/6 passed**, including repeated corrections
  and interruption/disconnect/reconnect.
- **Zero provider audio discontinuities** were recorded in the six live cases.

See the [new report](results-after-spoken-id-fix/report.json) and
[individual case results](results-after-spoken-id-fix/live.json). The run was
isolated, with no retries or relaxed acceptance assertions. The exact failed
transcript is covered by a production-parser/policy offline replay; the new live
correction run happened to transcribe the numbers as digits. This distinction
does not erase the earlier failure or imply universal transcription reliability.
