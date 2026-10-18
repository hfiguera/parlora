# Telnyx hangup reconciliation — September 24, 2026

## Observed cause

The completed human call ended normally on the caller side. Authenticated Telnyx
call-event history reported `hangup_source: caller`, `normal_clearing`, and SIP
cause `200`. In UTC, the call ended at `2026-09-25 03:13:12.540987`; media stopped
at `03:13:12.546305`. Delivery of the streaming-stop webhook began about 103 ms
before delivery of the hangup webhook. Locally, the cleanup command returned
HTTP 422 before the hangup webhook arrived. The original adapter discarded the
response body, so the exact historical rejection code is unavailable.

Media owner exit and streaming-stop handling both request bounded call cleanup.
They can run before a remote hangup is known. Replaying these transitions locally
confirmed that stop-first requests hangup, while hangup-first suppresses it.
This is compatible with Telnyx's documented
[unordered webhook delivery](https://developers.telnyx.com/docs/voice/programmable-voice/receiving-webhooks).

## Change

- Preserve at most eight unique, five-digit Telnyx error codes. Never retain raw
  response text, error titles, headers, or credentials.
- Exact HTTP 422 responses containing only error `90018` establish that the call
  ended. Mixed, malformed, unrelated, and non-422 responses do not.
- Preserve uncertain command execution, including when a transient failure was
  followed by an already-ended rejection. Do not manufacture command acceptance.
- Reconcile hangup failures with confirmed termination regardless of webhook and
  command-response order. Keep the original failure observation and append a
  `reconciled` / `call_ended` observation with its evidence source.
- Release the admission slot on confirmed termination, close remaining local
  resources, and suppress queued actions for ended calls. Genuine media failures
  still request hangup; unresolved errors still retain their slot.

The redundant request itself can still occur: media termination and call-ending
notifications travel independently. The fix makes the resulting state and
diagnostics accurate without adding an arbitrary delay to required cleanup.

## Verification

Protocol fixtures exercise exact `90018`, transient-then-ended, mixed/malformed
responses, unrelated 422 errors, code bounds, and private-response redaction.
Gate tests cover both webhook/response orders, already-ended responses without a
webhook, repeated terminal notifications, and genuine media failures retaining
unconfirmed admission slots. Existing tests cover owner death, late results,
credential expiry, draining, and independent concurrent calls.

| Check | macOS | Linux |
| --- | --- | --- |
| Library suite | 291 passed, 3 excluded | 291 passed, 3 excluded |
| Full standalone OrderDesk suite | 194 passed | 194 passed |
| Focused command tests after final assertion adjustment | 8 passed | 8 passed |
| Native checks, format, Credo, clone budget, Credence, Dialyzer | Passed | Passed |

The initial CI runs stopped at a test-style finding on Linux and a Rust toolchain
architecture mismatch on macOS. After correcting the assertion and selecting
the existing ARM macOS toolchain, the affected checks and remaining CI steps
passed. The full suites above passed before that assertion-only adjustment.

No new real phone call was placed for this change. The automated cases reproduce
the observed ordering; a subsequent handset call is still needed to observe the
new reconciliation diagnostics on the live network.
