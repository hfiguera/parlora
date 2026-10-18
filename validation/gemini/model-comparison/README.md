# Standard Live versus Extended Thinking — 2026-09-24

Standard `gemini-3.8-live` completed **5/5** bounded simulated tasks; Extended
Thinking at HIGH completed **1/5**. All four Extended failures spoke a system-error
message before emitting any tool call. This is stronger evidence of a difference
between the model/service paths than our earlier Extended-only failures. It does
not establish the provider's internal cause or guarantee standard Live reliability.
The successful Extended run confirms that its failure is intermittent.

| Task | Standard Live | Extended Thinking HIGH |
| --- | --- | --- |
| Turn on simulated lights, no arguments | 3/3 | 0/3 |
| Look up simulated order 124, required string argument | 2/2 | 1/2 |
| Total | 5/5 | 1/5 |

## Controls and evidence

The same Python SDK 2.25.0, v1alpha endpoint, Keychain credential, computer, prompt,
tool schema, immediate simulated result, continuous silent PCM stream, and
90-second deadline were used within each task. Sessions ran sequentially with
order varied between rounds. The SDK config snapshots are equal after removing
the Extended-only HIGH thinking config. Both models explicitly use NON_BLOCKING.
No scheduling field is sent. Standard Live omits thinking config, as required by
[its model documentation](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live).
Extended uses HIGH and waits for IDLE after intermediate utterances, as specified
in [its documentation](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live-extended-thinking).

[summary.json](summary.json) includes all ten run filenames, source/evidence hashes,
configuration comparison, observed tool calls, transcripts, timings and order of
execution. Individual reports retain the config, SDK version, UTC start, raw usage
metadata and sanitized events. Credentials and raw audio are not saved.

All setups completed. Standard Live called the tool in 696–972 ms from probe
start, including connection. Its final turn completed in 2.9–4.2 seconds.
The successful Extended order lookup called the tool at 7.8 seconds and completed
at 13.9 seconds. Its four failing sessions reached IDLE in 8.2–9.3 seconds, well
before the deadline. These are observed probe timings, not acoustic latency or
controlled performance estimates; there is only one successful Extended sample.

The final transcripts were inspected: standard returned the lights-on confirmation
or the supplied Friday delivery answer; the successful Extended answer also
correctly stated order 124 arrives Friday. The order-call arguments correctly
requested order 124. No real lights, orders, network tools or business actions
were executed by this fixture.

## Reproduction and checks

Use the diagnostic Python environment containing google-genai 2.25.0. Each command
runs one paid session, bounded at 90 seconds, and privately retrieves the stored
Keychain credential (or accepts GEMINI_API_KEY in the process environment):

```sh
python scripts/gemini_sdk_pilot.py --model gemini-3.8-live --minimal-tool --timeout 90
python scripts/gemini_sdk_pilot.py --model gemini-3.8-live-extended-thinking --thinking high --minimal-tool --timeout 90
```

Omit `--minimal-tool` for the order fixture. Preserve every run, including failures.
The exact order of this experiment is stored in summary.json.

Four offline diagnostic regression tests pass (`offline-tests.log`): standard
omits thinking and accepts final post-tool turn completion; Extended continues
past filler completion until IDLE; a system error after a tool response fails the
task; unsupported BLOCKING on Extended is rejected before credential retrieval.
Run `python scripts/gemini_sdk_pilot_test.py`. Ruff and formatting checks pass.

## Implication for Parlora

Standard Live merits a separate realistic OrderDesk pilot. This result does not
qualify it as a replacement: input was text plus silent audio, results were
immediate fixtures, and slow backend work, spoken corrections, interruptions,
clarification, browser saves, cancellation and reconnects were not exercised here.

No production library code, provider selection or default was changed. The
production Gemini adapter remains restricted to Extended Thinking; simply changing
its model string is not a supported integration. Full qualification of that
provider remains incomplete. The existing macOS/Linux library validation applies
to unchanged production code; the new diagnostic tests were run on macOS only.
