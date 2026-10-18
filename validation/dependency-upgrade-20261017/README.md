# Dependency upgrade review — October 17, 2026

Compared the shipped Hex source packages before changing the constraints, rather
than relying on version numbers or compilation alone. Root and OrderDesk use
exact pins; `Update not possible` reflected those pins, not an incompatibility
established by the solver. Historical call reports retain their original versions.

| Package | Before → after | Effect on Parlora |
| --- | --- | --- |
| Bandit | 1.12.5 → 1.13.1 | Stricter WebSocket key and HTTP authority/framing validation, corrected fragmented-frame telemetry, faster masking. Existing WebSock/Plug interfaces remain usable. |
| Jido | 2.3.3 → 2.4.0 | Optional complete-state byte budgets and validation/default fixes. Parlora's AgentServer start/cast/await API remains unchanged; OrderDesk does not enable the new budget. |
| Sagents | 0.16.0 → 0.17.1 | User-request metadata, durable approval/persistence changes, and argument pre-parsing. Parlora uses isolated `Agent.execute/3` with no middleware or AgentServer lifecycle; structured completion remains required. |
| Legion | 0.5.1 → 0.6.0 | New required tool callbacks, Help/eval support, retained-bindings limit and lifecycle changes. Implemented tool metadata callbacks; explicit model, prompt, native evidence and request isolation remain authoritative. |

Required dependency changes are Thousand Island 1.5.0 → 1.6.0, Jido Signal
2.3.0 → 2.3.2, Zoi 0.18.7 → 0.18.11 and LangChain 0.14.4 → 0.15.3. Other
previously locked packages remain unchanged, with one security exception below.

The LangChain diff extracts Chat Completions serialization into a shared module
and adds context-aware argument parsers. OrderDesk still uses OpenAI's
`ChatOpenAI` with explicit credentials, `gpt-6-luna`, reasoning `none`, synchronous
tools and its existing one-argument parser. It does not use the new
`ChatOpenAICompatible` model. Zoi stores defaults as metadata; the updated Jido
and Jido Signal sources explicitly accommodate this representation.

Legion's changed default model, MCP serving, persistence, recovery and sub-agent
APIs are not used. The request-bound tool now implements `summary/0` and
`mcp?/0`; the latter returns false. Added real Lua execution checks for Help and
for the exclusion of metadata callbacks from callable tool functions. The new
default retained-bindings limit is 10 MB; the adapter's existing time, heap,
reduction, tool-call and native-result limits remain in force.

Hex flagged the already-locked Decimal 3.1.1 for CVE-2026-97853. Included only
the reviewed 3.1.2 security patch: rounding no longer allocates according to
unbounded requested scale, and zero conversions avoid exponent expansion.
Decimal 3.2.0's broader arithmetic/rounding changes are outside this upgrade.

## Sources

Exact shipped packages were downloaded from `https://repo.hex.pm/tarballs/`
for both versions and compared with `git diff --no-index`. Package checksums
are retained in the two Mix lockfiles; Mix verifies fetched packages against
the registry.

- [Bandit 1.13.1](https://hex.pm/packages/bandit/1.13.1), `CHANGELOG.md`, WebSocket connection/upgrade validation, HTTP pipeline and dependency declarations.
- [Jido 2.4.0](https://hex.pm/packages/jido/2.4.0), AgentServer, agent state/budget/schema, storage and lifecycle diffs.
- [Sagents 0.17.1](https://hex.pm/packages/sagents/0.17.1), `CHANGELOG.md`, Agent/State/UserRequest execution and middleware diffs.
- [Legion 0.6.0](https://hex.pm/packages/legion/0.6.0), `CHANGELOG.md`, Tool, AgentServer, Eval, Lua sandbox, prompt and executor diffs.
- [LangChain 0.15.3](https://hex.pm/packages/langchain/0.15.3), ChatOpenAI, ChatCompletionsFormat, Function and LLMChain diffs.
- [Decimal security advisory](https://github.com/ericmj/decimal/security/advisories/GHSA-6c27-994x-c52f), 3.1.1 → 3.1.2 source diff.

## Validation

Results are recorded in [checks.json](checks.json):

- Full `mix ci`: 434 checks (428 tests and 6 properties), with 3 opt-in tests
  excluded; native tests, formatting, Credo, ExDNA, Credence and Dialyzer pass.
- Development compilation with warnings as errors, 20 Node runner tests,
  `mix hex.outdated --within-requirements` and `mix hex.audit` pass. All direct
  dependencies are current; no retired or advisory packages were reported.
- Fresh standalone consumers: Jido 222 tests, Sagents 225, Legion 226; all
  production release builds and offline release smoke checks pass. Default
  consumers still omit both optional backend frameworks.
- Offline release runner: evaluator checks, 6 acceptance cases, 3 browser
  recovery cases and interpretation diagnostics pass; cleanup has zero sessions.
- All 210 source files checked by consumer provenance match for each backend.

Initial concurrent consumer runs retained two failures: Jido's greeting test
timed out on a default 100 ms fake-session startup assertion, and Legion's
clarification test raced stopping a linked helper that had already exited.
Neither failing path calls an upgraded backend or HTTP dependency. Setup waits
now use the existing 1-second convention, and the clock helper uses ExUnit
supervision. Production greeting deadlines and assertions remain unchanged.
Jido's full rerun uses the original seed; both fixture files also pass under
the original Legion seed in all three consumers. The original failures remain
listed in `checks.json`; they are not counted as passing attempts.

These checks use deterministic models and local transports; they do not
constitute new paid voice calls, PSTN qualification or human listening tests.
