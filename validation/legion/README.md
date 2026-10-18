# Legion qualification — October 3, 2026

Legion **0.5.1**, ReqLLM **1.26.0**, Lua **1.0.2**, Vault **0.2.1**;
Elixir **1.20.4**, OTP **29.0.6**, macOS arm64. Jido remains the default.
Backend text model: **gpt-6-luna / reasoning none**, Responses API.
Voice: **grok-voice-think-fast-2.0 / HIGH**. Interpretation: **jev-1.13.0**.

Implementation commit: `db55b407b62d3ca7578df3b790ef92868832437f`. Qualification evidence is contained in
this commit; both commit IDs are reported in the completion response.

## Checks

| Check | Result / evidence |
| --- | --- |
| Full repository CI | **350 passed** (6 properties, 344 tests), 3 excluded. Native checks, strict Credo/ExSlop, zero-clone gate, Credence and Dialyzer passed. [Log](checks/parlora-legion-ci-qualified-20261003.log) |
| Dev warnings as errors | Passed. [Log](checks/parlora-legion-dev-compile-final-20261003.log) |
| Default consumer | **196 passed**; optional Legion/Lua/ReqLLM/Vault and Sagents/LangChain unavailable; compilation, production release and native Jido smoke passed. [Initial build](checks/parlora-legion-consumer-default-20261003.log), [final tests](checks/consumer-default-qualified-tests.log), [final release](checks/parlora-legion-default-release-clean-20261003.log) |
| Sagents consumer | **199 passed**; Legion stack absent. Existing adapter and business behavior passed after the shared lifecycle refactor. [Build](checks/parlora-legion-consumer-sagents-20261003.log), [tests](checks/consumer-sagents-qualified-tests.log), [release](checks/parlora-legion-sagents-release-clean-20261003.log) |
| Legion consumer | **199 passed**, including real Lua, two reads plus quantity calculation, invented-total rejection, bound authority, cached drafts, authenticated confirmation and explicit backend override. [Tests](checks/consumer-legion-qualified-tests.log), [release](checks/parlora-legion-legion-release-clean-20261003.log) |
| Evaluator tests | **20 passed**. [Log](checks/parlora-legion-evaluator-final-20261003.log) |
| Default offline release evaluation | All four stages passed. [Report](results/release-default/report.md) |
| Legion-enabled offline release evaluation | All four stages passed. The recovery protocol fixture explicitly uses Jido; its success alone is not Legion model qualification. [Report](results/release-legion/report.md) |
| Live Legion text tasks | **4/4 completed**: two ordinary lookups and two compound read/calculation tasks. [Report](results/text-legion-value-tools-20261003/report.json) |
| Assembled production release + Luna | **2/2 completed**, ordinary lookup and compound task; **Mix unavailable**. [Report](results/release-text-legion-20261003/report.json) |
| Grok HIGH + Legion + JEV | **3/3 synthetic browser cases passed**; zero active sessions afterward. [Report](results/grok-live/report.json) |

Controlled-model tests execute the actual Legion agent, executor and Lua VM.
They cover identity, concurrent request isolation, duplicate/conflicting commands,
retained rejection, ledger limits, model iteration/retry limits, tool-call budgets,
result size, CPU/memory/time limits, missing native completion, Lua mutation of
returned data, native failure status, cancellation races and status redaction.
Shutdown tests monitor the actual Legion agent, collector, Lua evaluator and
watchdog rather than an HTTP helper task. Owner death, worker crash, job deadline,
cancellation and both close policies terminate local execution without claiming
that external effects were undone. The substitution suite covers correction,
audio and stale results with all five existing channel fixtures.

## Live outcomes and comparison

The Grok/Legion browser sample passed:

- **12-correction:** current order 124 reached speech while the old revision stayed obsolete.
- **14-followup-items:** the separately admitted items follow-up completed and reached provider captions.
- **20-browser-confirmation:** voice created a draft without saving; browser confirmation saved once and received a verified announcement.

These use synthetic speech and browser media/captions. **Human listening and
Legion Twilio/Telnyx calls remain unqualified.** Existing Twilio 12200/TwiML was
left unchanged. Phone protocol coverage comes from deterministic substitution
fixtures, not live Legion telephone calls.

| Two sequential samples per task | Sagents | Legion |
| --- | --- | --- |
| Lookup median admission-to-result | 2.49 s | 4.46 s |
| Lookup model calls per request | 2 | 2 |
| Lookup input/output tokens per request | 426 / 24 | 1,052 / 124 |
| Compound median admission-to-result | 3.19 s | 2.06 s |
| Compound model calls per request | 2 | 1 |
| Compound input tokens per request | 517 | 476 |
| Compound output tokens per request | 54 | 104–114 |

[Computed comparison](checks/comparison.json),
[Sagents same-task report](results/text-sagents-comparison-20261003/report.json).
This is descriptive evidence from two samples, including cold-client overhead;
it is not a latency guarantee or significance test. Legion cost more tokens and
time for lookups in this sample; combining reads and Lua processing used one
model call for the compound task. Jido remains the simpler default.

## Retained failures and fixes

- Initial controlled tests failed because ReqLLM rejects `api_key` in model tuple
  defaults. Legion calls `generate_object/3`, so OrderDesk now configures the
  host-owned ReqLLM OpenAI key separately. [First run](checks/parlora-legion-first-tests-20261003.log),
  [configuration diagnosis](checks/parlora-legion-fixture-debug-20261003.log).
- A cold model-client startup exceeded an early one-second test deadline.
  Tests now leave startup room and separately exercise sandbox/job deadlines.
  ReqLLM finite total-timeout handling also used detached HTTP tasks; execution
  now keeps HTTP work in the agent and uses the adapter's finite outer deadline.
- Early multi-step fixtures stored counters in an HTTP helper process, resetting
  the counter on each call. Controlled calls now execute directly in the agent;
  cleanup assertions check its actual initial call and evaluator watchdogs.
- Initial live batches completed **2/4**, **3/4**, then **0/4**; a diagnostic batch
  completed **1/2**. All remain failures:
  [initial](results/text-legion-initial-20261003/report.json),
  [native-completion prompt](results/text-legion-final-20261003/report.json),
  [authority prompt](results/text-legion-authority-prompt-20261003/report.json),
  [diagnostic batch](results/text-legion-diagnosis-20261003/report.json).
  Legion's general prompt permitted returning a Lua value without native
  completion. Generated code also wrapped the tuple-array bridge again and
  treated a successful read as an error. The final integration requires native
  completion and exposes native values directly to Lua, with sanitized errors.
  [Sanitized diagnosis](checks/diagnosis.json). No failed attempt was overwritten. Retained console logs have trailing
  whitespace and terminal blank lines normalized; diagnostic content is unchanged.
- A probe launched from the library project instead of the consumer failed before
  API work. [Log](checks/parlora-legion-live-text-prompt-20261003.log).
- Early CI found alias ordering and fixture complexity issues. Subsequent runs
  passed all gates. Logs for each attempt are retained.
- Merging optional lock entries initially duplicated an identical `db_connection`
  entry in the canonical consumer lock. It was deduplicated; final compile and
  release checks passed. Dependency-origin deprecation/linker warnings on clean
  builds remain upstream; library/application warnings-as-errors checks passed.

## Provenance and boundaries

The [source audit](checks/source-audit.json) matched **198 files per consumer**,
including runtime, tests and native source, against current repository sources.
Text and voice reports record the source hashes that actually ran; older failed
reports retain older hashes. Release plans retain the pre-commit revision and
`git_dirty: true` accurately. The production text probe confirms `Mix` was absent.
Credentials were loaded privately into child environments and excluded from
retained artifacts. Raw synthetic audio, screenshots, databases and private
local diagnostic traces remain under `/tmp`; repository evidence keeps reports,
per-attempt observations, hashes and logs.

Cancellation remains advisory. No persistence, recovery, shared conversation,
subagent delegation, backend updates, progress or clarification is supported.
Sandbox budgets can overshoot by one 50 ms sampling interval. Trusted native
callbacks run under the job deadline, outside the Lua heap budget. ReqLLM OpenAI
credentials are host-owned provider-wide configuration, not separate credentials
per concurrent request. Legion's raw in-process telemetry must not be exported
through a verbose/default logger; Parlora events and probe telemetry retain only
sanitized outcomes, native results and usage numbers.

Configuration and complete human launch commands:
[Legion backend guide](../../docs/legion-backend.md).

## Reproduce

```sh
export ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none'
export RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin
mix ci
scripts/consumer.sh /tmp/new-default-consumer
PARLORA_BACKEND=legion scripts/consumer.sh /tmp/new-legion-consumer
PARLORA_BACKEND=sagents scripts/consumer.sh /tmp/new-sagents-consumer
PARLORA_BACKEND=legion scripts/release_check.sh /tmp/new-legion-consumer --output /tmp/new-release-report

# From the Legion consumer, using private Keychain credentials:
PARLORA_BACKEND=legion PARLORA_PROVIDER=grok BACKEND_PROBE_OUTPUT=/tmp/new-text-report \
  python3 scripts/with_keychain.py mix run /Users/humberto/Projects/parlora/validation/legion/probe.exs

# From the repository; paid synthetic checks, not human listening:
PARLORA_BACKEND=legion PARLORA_PROVIDER=grok GROK_REASONING_EFFORT=high \
  node validation/task-pilot/run.cjs /tmp/new-legion-consumer /tmp/new-voice-report \
  --live --repetitions 1 --cases 12-correction,14-followup-items,20-browser-confirmation
```
