# Highest thinking and tool-format investigation — 2026-09-24

Conclusion: HIGH did not resolve the live tool failure. No declaration-format defect
was found. Five bounded HIGH sessions produced zero successful task answers.
The full-provider qualification remains incomplete. These observations do not
establish Google's internal root cause or a global service outage.

## Wire-format audit

Current [official thinking documentation](https://ai.google.dev/gemini-api/docs/live-api/thinking)
identifies LOW, MEDIUM and HIGH as supported levels and requires NON_BLOCKING
functions. Parlora uses the documented raw JSON nesting:
`setup.tools[].functionDeclarations[]`, with `behavior: "NON_BLOCKING"`, an OBJECT
schema, a STRING `request` property and `required: ["request"]`.

[The offline audit](schema-audit.json) exports setup from the production Elixir
protocol using a dummy credential, then captures the actual serialization from
Google's Python SDK 2.25.0 with its WebSocket replaced by an offline socket.
It confirms:

- Tool declarations match exactly, including descriptions, schema and behavior.
- Both implementations select HIGH. SDK serialization uses `thinking_level`;
  Parlora uses the documented `thinkingLevel`.
- Function-response bodies match exactly: correlated ID, function name and
  object response. SDK uses the root `tool_response`; Parlora uses the documented
  `toolResponse`. Neither sends unsupported scheduling metadata.

This checks client serialization; it does not independently prove how the server
executes a declaration. Authenticated SDK and production-adapter connections were
also exercised below. No production protocol change was justified by this audit.

Reproduce offline with `python scripts/gemini_schema_audit.py` in the diagnostic
Python environment containing google-genai. No real key or network is used by
that audit.

## HIGH live results

All sessions used `gemini-3.8-live-extended-thinking`, continuous input audio and
a 90-second cap. SDK requests used user text plus silent audio on v1alpha;
the production adapter used synthetic spoken order 124 on its default v1beta.
The first three sessions ran concurrently; the later SDK repeats were separate.
They are diagnostic fixtures, not human-conversation or business qualification.

| Evidence | Tool calls | Outcome |
| --- | --- | --- |
| [SDK minimal 1](sdk-high-minimal-1.json) | One at 12.5 s | After receiving the matching simulated result, spoke a system error at 16.6 s; IDLE at 19.3 s |
| [SDK minimal 2](sdk-high-minimal-2.json) | None | Spoke a system error at 8.1 s |
| [SDK order 1](sdk-high-delegate-1.json) | None | Spoke a system error at 4.0 s |
| [SDK order 2](sdk-high-delegate-2.json) | None | Spoke a system error at 25.7 s |
| [Production audio adapter](adapter-high-1.log) | None | Correctly captioned order 124; spoke a system error at 9.1 s; probe ended at its 90-second deadline |

The minimal-1 raw report retains `passed: true` from the earlier diagnostic's
loose predicate (tool observed plus IDLE). That is **not a task success**: its
recorded final transcript is a system error. The pilot now separates
`protocol_completed` from `passed`, requires the expected result in the
post-tool transcript, and rejects system-error responses. Original evidence has
not been rewritten. The new check is a conservative fixture check, not a general
semantic evaluator.

The changed SDK pilot supports `--thinking high --timeout 90`; the adapter pilot
supports `GEMINI_THINKING_LEVEL=high GEMINI_PILOT_TIMEOUT_SECONDS=90` and now records
both settings. Credentials continue to come privately from Keychain. The default
production thinking level remains LOW because this experiment provides no
successful evidence for changing it.

## Checks and remaining uncertainty

Python Ruff checks and formatting pass. The offline SDK wire audit passes.
[Focused protocol and adapter tests](high-investigation-tests.log): 11 passed on
macOS. This investigation changes diagnostic scripts and evidence only; the
previous macOS/Linux production verification still applies to unchanged library
code. It adds no live qualification for cancellation, business corrections or
reconnect safety.

The practical finding is narrower than an identified root cause: increasing
reasoning did not fix these fixtures, and the same failure occurs through Google's
SDK outside Parlora. No malformed tool declaration was found. Further investigation
needs a consistently successful reference exchange or actionable server diagnostics.
