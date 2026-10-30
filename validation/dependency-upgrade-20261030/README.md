# Dependency upgrade review — October 30, 2026

Base: `6f8ad69`. Branch: `dependency-upgrades`. Parlora stays at version 0.2.0;
release preparation is separate from this dependency change.

The four requested direct upgrades require four additional transitive upgrades.
Plug.Crypto's existing advisory was identified during resolution, and its patch
release is included as well. The root and canonical OrderDesk lockfiles change
the same nine package versions; other lock entries remain unchanged.

## Source review

Compared the actual old and new published Hex package contents, including native
code and dependency declarations. Package archive SHA-256 values were checked
against the Hex release API. The [source manifest](source-review-summary.json)
records both archives and the full package-diff hashes. Downloaded source trees
and full diffs remain outside the repository.

| Package | Upgrade | Reviewed impact on Parlora |
| --- | --- | --- |
| Bandit | 1.13.1 → 1.14.1 | Reviewed WebSocket handshake, frame reassembly, shutdown dispatch, request parsing, and response handling. HTTP/1 and HTTP/2 handling is stricter and bounded. After a server close, further frames/messages no longer reach the terminated handler. Parlora uses valid Plug requests, disabled WebSocket compression, finite frame/timeout limits, and normal WebSock callbacks. Browser and phone socket tests exercise these paths. No transport adaptation was required. |
| ExWebRTC | 0.17.0 → 0.18.0 | Reviewed peer-connection configuration, DTLS setup, ICE statistics, RTP/RTCP sender/receiver statistics, and transceiver changes. The custom ICE transport callback changes from `get_stats/1` to `get_stats/2`; Parlora uses the default transport. PeerConnection APIs used by the browser channel retain their signatures. Additional stats, timeout fallbacks, and optional pre-generated certificates require no change to our audio path. |
| WebSockAdapter | 0.6.0 → 0.7.0 | Reviewed upgrade dispatch, new Plug wrapper, and Cowboy termination handling. The Bandit adapter tuple and `upgrade/4` API are unchanged. Cowboy error-close behavior changes; our termination callbacks ignore the reason and close the session. Network checks use Bandit. Roadrunner support is optional and does not install a new server dependency. |
| Sagents | 0.17.1 → 0.19.2 | Reviewed agent construction/execution, ability-set dispatch, loop steps, state merge, and completion handling. New ability sets, tool search, and refusal budgets are opt-in. Parlora requires empty middleware, synchronous tools, no fallbacks, and request-local execution. The no-ability-set path retains the agent's own tools/prompt; `execute/3`, bounded `max_runs`, and successful terminal ToolResult mapping remain compatible. |
| ExDTLS | 0.18.1 → 0.18.2 | Required by ExWebRTC. Reviewed the C fragmentation BIO initialization and NIF declarations. Initialization now uses OpenSSL's once primitive to prevent concurrent initialization races; RSA generation runs on dirty CPU schedulers. Public calls used by ExWebRTC are unchanged. Actual WebRTC audio and concurrent-peer checks cover native negotiation. |
| LangChain | 0.15.3 → 0.15.7 | Required by Sagents. Reviewed chain tool execution/failure accounting, Function parsing, ToolResult flags, ChatOpenAI serialization, and message changes. Repeated identical tool errors gain a corrective hint; refusals are marked separately while remaining errors. Default retry limits and synchronous tool support remain available. Ordinary function tools retain their Chat Completions encoding, and `processed_content` is preserved. |
| ReqLLM | 1.26.0 → 1.29.0 | Required by LangChain when ReqLLM is installed for Legion. Reviewed structured generation, OpenAI request/response handling, schema caching, authentication, startup, model selection, and retry changes. `generate_object/3` and the structured-output tool contract remain compatible. Releases now skip automatic `.env` loading unless enabled; hosts already supply credentials explicitly. HTTP transient-status retry coverage expands, while the OrderDesk Legion model explicitly disables transport retries and Parlora retains its execution deadline. |
| LLMDB | 2026.9.8 → 2026.10.7 | Required by ReqLLM. Reviewed execution-contract enrichment and the catalog entry used by the Legion fixture/example. `openai/gpt-6-luna` keeps its text/object Responses API routes and reasoning options; evaluation capability is additive. Added hosted-Claude enrichment does not change the example's OpenAI path. |
| Plug.Crypto | 2.2.0 → 2.2.1 | Reviewed signing, verification, encryption, decryption, and malformed-payload handling. Invalid arguments now avoid secret-bearing function-clause traces; malformed tokens return invalid results. Normal signing/encryption algorithms remain unchanged. This resolves the existing CVE-2026-105963 advisory. OrderDesk cookie/session behavior is covered by its tests and browser checks. |

No provider/channel/backend algorithm changes were required. Runtime source
changes only update the Sagents installation hint in its module documentation
and missing-dependency error. The canonical example and optional-backend fixture
select the new versions; the downloaded historical validation records remain
unchanged.

## Validation

All checks below passed with the final nine-package snapshot. The three Linux
checkouts have the same `mix.lock` SHA-256 as the Mac checkout. The source
manifest also records result counts, source hashes, and detailed-log hashes.
Consumer and browser checks ran on macOS; Linux coverage includes full CI, the
older OTP toolchains, and the explicitly enabled stability suite.

| Check | Result |
| --- | --- |
| macOS arm64, Elixir 1.20.4 / OTP 29.1.2, full `mix ci` | 603 checks passed; 3 excluded by default. Native formatting, Clippy and Rust tests, compile-cycle checks, formatting, strict Credo, ExDNA, Credence, and Dialyzer passed; zero Dialyzer errors. |
| Linux x86_64, Elixir 1.20.4 / OTP 29.1.2, full `mix ci` | 603 checks passed; 3 excluded by default. All native and static checks passed; zero Dialyzer errors. |
| Linux Elixir 1.18.5 / OTP 27.3.4.15 and Elixir 1.19.5 / OTP 28.5 | Compilation and tests with warnings as errors, plus compile-cycle checks, passed on both toolchains. No test failures. |
| Linux stability suite, explicitly enabled with seed 42 | 3 tests passed, including 100 repeated session cycles and 500 corrections. |
| Packaged default OrderDesk consumer | 248 tests passed; production compilation, release assembly, and offline release smoke passed. |
| Packaged Sagents OrderDesk consumer | 251 tests passed; production compilation, release assembly, and offline release smoke passed. |
| Isolated optional-backend consumers | Custom-only: 11 tests; Jido: 33; Sagents: 24; Legion: 35. All passed test/prod compilation, release assembly, dependency-isolation assertions, and release smoke. |
| Browser audio gates | 200 seeded matrix cases passed, plus steady, jitter, burst, variable, interruption, disconnect, and reconnect browser scenarios. |
| Browser concurrency | Warmup and 1/2/4-session cohorts passed, including stalled-provider and disconnected-provider containment, admission limits, and cleanup. |
| Browser UI and exact guide client | Permission denial, origin rejection, three voice cycles, signaling-loss cleanup, two guide-client cycles, and OrderDesk cookie/save/confirmation/retry/UI checks passed. |
| JavaScript helper/evaluator suites | 48 tests passed. |
| Strict documentation generation | `MIX_ENV=dev mix docs --warnings-as-errors` passed. |
| Plug.Crypto patch probe | Valid signing/encryption round trips, malformed-token rejection, and six invalid-argument secret-redaction checks passed using synthetic secrets. |
| Locked versions | `mix hex.outdated` reports every direct dependency up to date. Both lockfiles change exactly the nine reviewed versions; final package archive hashes match the source review. |

Detailed logs, downloaded source trees, full package diffs, and standalone
consumers are retained locally under `/tmp/parlora-dependency-upgrades-20261030`.
Linux evidence is also retained under
`/home/humberto/codex-validation/parlora-dependencies-20261030` on the `linux` SSH
target. The initial resolver offered additional unrelated upgrades; those were
restored before validation. Initial eight-package checks were followed by final
nine-package runs after including Plug.Crypto's patch.

These checks are offline: they use synthetic media, local WebSocket/WebRTC peers,
native backend fixtures, and synthetic credentials. No new live-provider calls,
human listening tests, or physical microphone/speaker tests are claimed.
