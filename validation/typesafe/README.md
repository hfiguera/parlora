# TypeSafe evaluation for the order application

Evaluated September 16, 2026 (Mountain time; September 17 UTC). This standalone
Mix fixture evaluates `typesafe_ai` **0.1.0** as a possible component of the
consumer application's `ContextPolicy`. It does not add a dependency to Parlora
or change the running consumer. No order lookup or database write is executed.

## Recommendation

**Proceed with TypeSafe-assisted intent and order selection in the example app,
with application-owned validation and clarification. Do not use raw model
decisions as business authorization or as complete Parlora decisions.**

The small run supports its latency and basic classification suitability. It does
not establish production accuracy, trustworthy confirmations, or suitability for
arbitrary extraction. The most serious failure was classifying an explicit
refusal as approval in both repeats. Keep writes disabled until the application's
confirmation protocol and further refusal/conditional-approval evaluations pass.

## Method

- macOS, Elixir 1.20.4 / Erlang 29.0.6; dependency versions are in `mix.lock`.
- Real TypeSafe service, requested model `jev-latest`, returned `jev-1.13.0`.
- Six development/sanity cases and 24 labeled challenge cases, the latter run
  twice: **54 requests**. All four classifications are batched in each request.
- Labels and questions were written before any live calls. The challenge set is
  marked `held_out` in artifacts. It is a hand-authored evaluation by the same
  author as the prompt, not an independently curated blind benchmark. Neither
  labels nor case IDs/split are sent to the service. No prompt/label changes or
  post-run tuning were used to improve these results.
- Four outputs: business intent, relationship to the active task, selected order,
  and approval/refusal of a pending change. Relation labels have precise application
  semantics: a different operation on the same order is a new task.
- Inputs are complete synthetic snapshots, including explicitly supplied order
  candidates, active task metadata and pending proposals. This tests classification
  **conditional on these inputs**, not number extraction, proposal extraction,
  speech recognition, or an integrated streaming voice call.
- Single reusable supervised client, concurrency one, queue one, 4-second request
  timeout, 2-second connect timeout, one attempt, no retries. Each request is timed
  end to end around `TypeSafe.system_one/2`, including encoding and parsing.
- A probability gate was fixed at **0.8 for every selected answer** before the
  run. This uses the chosen label's probability, not the separate `confidence`
  field. Gate acceptance is an evaluation metric, never permission to write.

The application key was retrieved from macOS Keychain service `typesafe_ai`,
account `api_key`, directly into process memory and supplied as `api_key:`. No
secret was displayed, logged or saved. Authentication succeeded in all live calls.

## Results

| Measurement | Result |
| --- | --- |
| Successful API requests | 54 / 54; no transport, HTTP or validation errors |
| Development cases, all four answers correct | 6 / 6 |
| Challenge evaluations, all four answers correct | **41 / 48 (85.4%)** |
| Challenge intent | 48 / 48 |
| Challenge target order | 48 / 48 |
| Challenge task relationship | 45 / 48 |
| Challenge confirmation | 44 / 48 |
| Challenge predictions identical across repeats | 23 / 24 cases |
| Challenge evaluations passing 0.8 gate | 27 / 48 (56.3% coverage) |
| Correct among those passing the gate | 26 / 27 (96.3%) |
| False approvals before gate | **2 evaluations of the same refusal** |
| False approvals passing gate | 0 in this sample |
| All-request latency, median / p95 / max | **161 / 317 / 497 ms** |
| Challenge latency, median / p95 / max | 166 / 288 / 323 ms |
| Requests exceeding Parlora's 5-second policy deadline | 0 |
| Reported token usage | 77,191 input; 11,050 output |

Percentiles use the nearest-rank method. Repeated evaluations of the same cases
are not independent evidence from 48 different conversations. No dollar cost was
estimated. Reported token counts are preserved; no pricing assumption was made.

### Failures retained without relabeling

| Case | Expected behavior | Observed |
| --- | --- | --- |
| `h01`: order number supplied after clarification, no active task | New task | One repeat said same task; the other was correct. Wrong answer failed the probability gate. |
| `h08`: ask for items while status lookup exists | New operation/task | Both repeats said same task. One wrong answer passed the gate (relationship probability 0.82). |
| `h18`: “No, leave the instructions as they are.” | Reject pending update | **Both repeats said approve**, probability 0.68 and 0.63. Both failed the gate. |
| `h22`: replace reception with neighbor | Correction; confirmation unclear because proposal changed | Both said reject for confirmation. No false approval, but did not match the declared label semantics. |

`h22`'s rejection is understandable conversationally; it is counted wrong because
the predeclared contract distinguishes refusal from a modified proposal. Together
with `h08`, this shows why lifecycle mapping should be explicit Elixir logic. The
two `h18` answers are a substantive refusal-recognition failure, not just a
disagreement about task labels. A confidence threshold is not a guarantee.

## Failure behavior and scope of evidence

Six offline tests pass, covering fixture labels/question options, scorer and
summary correctness, a stalled HTTP service hitting its deadline, cancellation
of an outstanding HTTP/1 request when its caller dies, and surfacing a 429 without
retry under the chosen one-attempt configuration. The failure fixtures use a
synthetic key and a local TCP server; the 54 live calls did not experience these
failures. Compilation with warnings as errors and formatting checks pass.

These tests do not establish behavior under concurrent production load, real
rate limits, a long outage, or HTTP/2 cancellation. No Linux run was needed for
this bounded macOS service evaluation; no Linux result is claimed.

Parlora already rejects policy results whose snapshot revision became stale.
Even a 161 ms evaluation can be stale while transcript fragments arrive. This
probe does **not** exercise that runner. Integration must measure discarded
evaluations and useful decision latency, coalesce appropriate context changes,
preserve the five-second outer deadline, and provide explicit unresolved/error
behavior. A fast HTTP response alone does not prove fast user-visible decisions.

For the next application implementation:

1. Classify intent and select among application-extracted order candidates;
   clarify missing or uncertain information.
2. Derive task identity, new-operation versus same-operation mapping, allowed
   actions and current revisions from application state. Keep model output
   advisory and validate combinations.
3. Keep exact delivery text extraction as a separate problem. Before enabling
   writes, bind confirmation to the exact proposal/order/revision and enforce
   authorization and durable operation idempotency in application code. Add
   independent confirmation tests; do not rely on the probability gate alone.
4. Measure the integrated streaming policy and failure recovery before calling
   this ready for real users.

## Reproduce

From this directory, with the repository's pinned BEAM runtime:

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test
# Makes 54 bounded, billable requests; overwrites results.json:
mix run scripts/evaluate.exs --live-keychain
```

The script never prints the Keychain command's output, including retrieval errors.
Do not enable shell tracing or print the secret. The fixture makes no GPT-Live
calls and starts no audio devices.

Artifacts: [cases](cases.json), [frozen questions/scorer](lib/evaluation.ex),
[runner](scripts/evaluate.exs), [full results](results.json). The report includes
SHA-256 hashes of the case file and evaluator, timings, returned model, expected
and actual labels, probabilities, confidence and token usage for every call.

References: [TypeSafe HTTP API](https://docs.typesafe.ai/api),
[Elixir client 0.1.0](https://github.com/hfiguera/typesafe_ai/tree/v0.1.0),
[Parlora ContextPolicy](../../docs/public-interfaces.md#7-parloracontextpolicy).
