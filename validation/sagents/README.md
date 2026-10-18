# Sagents qualification — October 3, 2026

Implementation commit: `0d66161`. Sagents **0.15.1**, LangChain **0.14.4**,
Elixir **1.20.4**, OTP **29.0.6**, macOS arm64. Hex listed Sagents 0.16.0 as
latest; the requested, non-retired 0.15.1 release was pinned and tested.

Backend: **`gpt-6-luna`**, Chat Completions, **reasoning `none`**.
Voice: **`grok-voice-think-fast-2.0`**, **HIGH**.
Application interpretation: **`jev-1.13.0`**. Jido remains the default.

## Checks

| Check | Result / evidence |
| --- | --- |
| Full repository CI | 323 passed (6 properties, 317 tests), 3 excluded; native checks, strict Credo/ExSlop, zero clones, Credence and Dialyzer passed. [Log](checks/ci.log) |
| Dev warnings as errors | Passed. [Log](checks/dev-compile.log) |
| Standalone default consumer | 195 tests, package compilation, production release and native Jido smoke passed. [Build](checks/consumer-default-build.log), [release smoke](checks/release-default-native-smoke.log) |
| Optional stack absent | Sagents, LangChain, Ecto and Phoenix PubSub unavailable; adapter reports unsupported, default Jido works. [Check](checks/consumer-absent-stack.log) |
| Standalone Sagents consumer | 198 tests; final dev/prod compilation and release assembly passed. [Tests](checks/consumer-enabled-tests-final.log), [release](checks/consumer-enabled-release.log) |
| Evaluator regression tests | 20 passed. [Log](checks/evaluator-tests.log) |
| Default release evaluation | All four offline stages passed. [Report](results/release-default-final/report.md) |
| Sagents-enabled release evaluation | All four offline stages passed; recovery protocol fixture explicitly uses Jido. Consumer tests include the real Sagents offline fixture. [Report](results/release-enabled-final/report.md) |
| Live Luna text probe | Three concurrent, separately identified requests completed: status, items and a status+items overview. [Report](results/text-20261003-1326/report.json) |
| Assembled production release + Luna | Same three requests completed, with `mix_available: false`. [Report](results/release-text-20261003-1330/report.json) |

Offline tests execute the real Sagents tool loop using a controlled model. They
cover structured completion, concurrency, duplicate/conflicting commands, retained
admission rejection, failures, finite deadlines, advisory cancellation, close,
owner death and status redaction. The substitution suite adds Sagents to all five
channel fixtures and proves current correction results reach context while old
results remain stale. OrderDesk fixture tools reject invented arguments, require
actual reads before finish, cache repeated operations, and cannot save drafts.

## Live voice outcomes

The final [Grok/Sagents report](results/grok-live-20261003-1326/report.json) passed
all three scheduled scenarios:

- **12-correction:** order 123 remained slow while the caller corrected to 124.
  The current result was spoken; the old revision stayed obsolete after settling.
- **14-followup-items:** status and a separately admitted items follow-up both
  completed and received the expected provider captions.
- **20-browser-confirmation:** voice created a reception draft without saving it;
  explicit browser confirmation saved exactly once and received a verified save
  announcement.

An earlier [valid run](results/grok-live-20261003-1322/report.json) also passed 3/3.
The final run followed the explicit-backend configuration fix and lockfile cleanup.
These are small synthetic-speech samples using browser media and provider captions,
not human listening, acoustic playback certification or production success rates.
Human Sagents calls and Sagents telephony qualification were not performed.

## Retained failures

- The [first voice batch](results/grok-live-20261003-1318/report.json) failed all
  three attempts in the optional diagnostics check after each requested outcome
  had completed. The collector was not available for Grok. These attempts remain
  failures; subsequent runs omitted the unsupported diagnostic flag.
- The [first enabled offline release](results/release-enabled-initial-failure/report.md)
  failed call readiness because its local protocol fixture inherited Sagents
  without a model credential. The fixture now explicitly selects Jido and the
  plan records `offline_recovery_backend: "jido"`.
- Initial consumer builds exposed an unreachable fallback warning after extracting
  confirmation. The business operation now reports an unavailable outcome when
  the store exits. Both [initial](checks/compile-warning-attempt-enabled.log) and
  passing build logs are retained.
- A [randomized fixture failure](checks/consumer-test-fixture-failure.json) assumed
  an empty shared audit log. The corrected assertion compares the before/after
  log, and all 198 tests passed with the original failing seed, 333065.
- A [text-probe directory failure](checks/probe-directory-failure.log) occurred
  before any API call; the runner now creates the parent directory.

## Provenance and limits

Final voice and release text reports record backend/voice/interpretation models,
reasoning settings and hashes of their consumer and library runtime sources.
The [runtime audit](checks/source-audit.json) found no mismatches across 130/131
recorded files. The [release audit](checks/release-source-audit.json) found none
across 189 files per consumer, including tests and native source. Reports were
captured before the implementation commit and correctly retain `git_dirty: true`;
their source hashes establish what actually ran.

Generated SQLite files, synthetic WAVs, copied runner source and raw media remain
locally at `/tmp/parlora-sagents-retained-raw-20261003`; the repository retains
reports, per-attempt observations, source hashes and logs. API credentials were
retrieved privately into child environments and are absent from this evidence.

Cancellation remains advisory: stopped local execution produces uncertainty, not
proof that external effects were undone. Updates, progress and clarification are
unsupported. The direct overview probe demonstrates bounded read orchestration;
it does not add a voice intent or write authority. Luna tool reasoning beyond
`none` requires a separate Responses API integration.
