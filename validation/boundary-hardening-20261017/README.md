# Policy and Jido boundary hardening — October 17, 2026

Validated on macOS arm64, Elixir 1.20.4 / OTP 29.1.2, Rust 1.92.0.

## Context-policy failure

A timeout or task crash previously cleared the active policy task without
processing newer caller context. A returned error on the current snapshot also
left interpretation unresolved. Finished backend results could remain held with
the session still ready until another external event triggered interpretation.

The coordinator now retries interpretation once against the latest snapshot and
trigger. It never replays backend operations or releases results on the strength
of a failed interpretation. A successful decision batch restores the retry
budget. More context arriving during failures does not reset that budget. A
second consecutive failure emits an explicit session failure and starts bounded
shutdown; unfinished external work remains uncertain. Interpretation workers
cannot extend their deadline by trapping their supervisor's shutdown signal.

Regression cases cover timeout, crash and returned error; pending corrections;
stale-result suppression; late task results/DOWNs/deadlines; retry-budget reset;
repeated failures with newer context; and real deadline expiry/cleanup. Admission
rejections remain separate `:policy_rejected` events.

## Jido result mapping

Jido previously constructed BackendResult directly from mapper output. An invalid
status reached an exhaustive case in the shared adapter and crashed it, affecting
other requests. It now validates status, facts, summary and the 64 KiB mapped
result budget inside the job. Mapping exceptions and throws become correlated
`:request_uncertain` observations with `reason: :invalid_result`. Other requests
continue, duplicate admission does not rerun the operation, and close retains
the uncertain request identity.

Explicit Jido cancellation and verified failure mappings remain supported. The
shared validator defaults still reject cancellation claims from Sagents/Legion;
their local stop cannot confirm cancellation of external effects.

## Results

The eight policy regressions and eight malformed Jido mapping cases failed before
the implementation changed. All pass after the fix. Twenty tests were added in
total, including valid-outcome and framework cancellation-contract checks.

| Check | Result |
| --- | --- |
| Focused policy and all backend adapters | 56 passed |
| Policy/Jido regressions, seeds 1–10, two BEAM schedulers | 19 passed per run; 190 checks |
| Root `mix ci` | 454 passed: 448 tests and 6 properties; 3 separate stability exclusions |
| Native and static checks | Rust tests/fmt/strict Clippy, format, strict Credo, clone/Unicode checks, Dialyzer passed; zero Dialyzer errors |
| Explicit stability suite, seed 42 | 3 passed |
| Fresh packaged OrderDesk | 222 passed; native production release and Jido correction smoke passed |
| Fresh consumer, no agent framework | 11 passed |
| Fresh consumer, Jido only | 22 passed |
| Fresh consumer, Sagents only | 24 passed |
| Fresh consumer, Legion only | 35 passed |

Every isolated consumer compiled in dev/test/prod with warnings as errors, checked
framework absence, built a production release and completed a custom backend
session without Mix. The one-framework profiles also ran that adapter's tests.
Upstream dependency builds retain existing warnings.

Reproduce with `mix ci`, `mix test test/stability_test.exs --include stability
--seed 42`, `scripts/consumer.sh /new/order-desk`, and the four profiles documented
in [optional backend isolation](../optional-backends/README.md).

## Manual follow-up

The tested production release was then started on port 4300 with WebRTC,
GPT Live 1 and Jido 2.4.0. The user completed a roughly 73-second call and
reported that it sounded good. Session `wQK-AOaFN5grrGcMKXSWL-vm` handled the
124-to-123 correction, completed all five Jido requests and received provider
acceptance for all five results. The delivery draft was confirmed and saved for
order 123 as record version 4.

The downloaded `parlora-audio-diagnostics (9).json` report was complete: 7,282
received RTP packets, zero packet loss/concealment and zero dropped provider
audio bytes. Three gaps had nonquiet samples on both sides: approximately
480, 20 and 70 ms. The first comprised about 370 ms without available source
audio plus 110 ms of recovery buffering. These remain playback observations,
not proof of what the caller heard; the user accepted the listening experience.

This live call exercises the normal conversation path. The deterministic tests
above cover injected policy failures and invalid result mappings. No separate
physical-device acceptance runs or Linux checks were performed for this change.
