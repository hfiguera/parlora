# Sagents 0.16.0 upgrade — October 3, 2026

Upgraded the library and canonical OrderDesk consumer from Sagents **0.15.1**
to **0.16.0**. LangChain stays **0.14.4**; every other locked dependency stays
unchanged. Elixir **1.20.4**, OTP **29.0.6**, macOS arm64.

No adapter migration was required: Parlora calls request-local
`Sagents.Agent.execute/3`, uses empty middleware and synchronous tools, and does
not use the distributed session factories/routers changed in 0.16.0.
See the [upstream changelog](https://github.com/sagents-ai/sagents/blob/v0.16.0/CHANGELOG.md).

| Check | Outcome |
| --- | --- |
| [Full CI](checks/ci.log) | 361 passed: 6 properties, 355 tests; 3 excluded. Native checks, strict Credo, zero clones, Credence and Dialyzer passed. |
| [Dev compile](checks/dev-compile.log) | `mix compile --warnings-as-errors` passed. |
| [Packaged Sagents consumer](checks/consumer-sagents.log) | 199 tests passed; test/prod compilation, production release assembly and native Jido smoke passed. |
| [Default consumer rerun](checks/default-consumer-retry.log) | All 196 tests passed with original seed 12617; prod compilation, release and native smoke passed. Release assertions verified Sagents, LangChain, Ecto and Phoenix PubSub absent. |
| [Offline release checks](release/report.md) | Evaluator tests, acceptance, browser recovery and interpretation diagnostics passed. Zero active recovery sessions remained. Recovery protocol fixture explicitly uses Jido. |
| [Production Luna probe](production-probe/report.json) | Three concurrent native Sagents requests completed: status, items and status+items overview. Actual runtime version 0.16.0; Mix unavailable in the assembled release. |
| [Live Grok/Sagents pilot](live/report.json) | Both scheduled synthetic browser scenarios passed; zero active sessions remained. |

Live voice used **grok-voice-think-fast-2.0 / HIGH**. Sagents used
**gpt-6-luna / reasoning none**, with application interpretation **jev-1.13.0**.

- [Correction](live/12-correction-r1.json): 123's deliberately slow lookup was
  superseded by 124. The current delivery status was answered; the obsolete
  revision remained stale after settling, without replay or extra lookup work.
- [Browser confirmation](live/20-browser-confirmation-r1.json): voice created
  a pending reception draft without saving it. Explicit browser confirmation
  saved its exact instructions once, left other orders unchanged, and produced
  a verified save announcement in a separate caption segment.

## Manual WebRTC call

After the automated checks, the caller tested **GPT Live 1 + Sagents 0.16.0**
using **gpt-6-luna / reasoning none** at `http://localhost:4300/`, approximately
20:13:47–20:15:05 MDT. Browser observations showed five backend requests completed
and all five result deliveries accepted, with no backend failure or delivery
rejection event. Correction from 123 to 124 produced its out-for-delivery status;
items and existing delivery instructions were answered. Browser confirmation
applied the new instructions once to 124, advancing record version 2 to 3.
The session disconnected and the health endpoint reported zero active sessions.
The caller explicitly confirmed the call was good.

The draft prompt and save announcement appeared in the same caption row, a UI
limitation observed during this call. The interpretation counter recorded eight
error/uncertain judgments across 28 calls; available server logs do not classify
each judgment. All admitted backend work nevertheless completed. No raw human
transcript or audio is included in this qualification record.

## Retained failures

The [initial resolver](checks/deps-initial.log) also upgraded Finch and Zoi.
The newer Zoi removed `Zoi.Types.Default`, breaking Jido Signal compilation in
the [initial CI attempt](checks/ci-initial-transitive-failure.log). Restoring both
existing lock entries limited the final change to Sagents. Final locked
resolution and full CI passed; no Jido workaround was needed.

The [initial default-consumer run](checks/consumer-default-initial-failure.log)
passed 195/196 tests. Its greeting test timed out waiting for a subscription
message within ExUnit's default 100 ms, while several fresh builds ran in
parallel. The same-seed rerun passed all 196 tests without source changes after
the concurrent build load subsided. This is consistent with scheduling
sensitivity; the initial failure remains recorded.

## Provenance and limits

Reports retain source hashes, the pre-upgrade commit `d73dd4d`, and
`git_dirty: true`. Current runner metadata records Sagents 0.16.0; the historical
[0.15.1 qualification](../README.md) is unchanged. The
[evidence manifest](evidence-sha256.json) hashes retained logs and reports.

Synthetic speech and provider captions establish the two automated outcomes.
The subsequent manual WebRTC call adds the caller's listening confirmation for
GPT Live 1; no 0.16.0 Twilio/Telnyx call was tested. The manual WebRTC server was
restarted from the new consumer; other manual servers kept their installed
dependencies. No production success rate or acoustic measurement claim is made.

Raw synthetic audio, screenshots, SQLite fixtures, copied pilot source and
additional release-fixture observations remain in `/tmp/parlora-sagents-016-*`.
The new standalone consumers are `/tmp/parlora-sagents-016-consumer-20261003`
and `/tmp/parlora-sagents-016-default-consumer-20261003`. API keys were retrieved
privately by the consumer launcher and are absent from the retained evidence.
