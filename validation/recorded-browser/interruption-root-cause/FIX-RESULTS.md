# Interruption number handling fix — September 17, 2026

## Changes

All production changes are in the example application's policy helpers. Parlora's
public interfaces and runtime are unchanged.

- Before classifying an open cardinal number such as “one hundred” or “one hundred
  twenty”, the policy waits for 600 ms of unchanged meaningful caller input.
  `number_settle_ms` configures this delay through the `AppPolicy` options, within
  Parlora's existing 1–60,000 ms recheck bound. A new fragment replaces the old wait.
  Complete 123/124 phrases and unrelated requests do not acquire this delay.
- A genuine request for 100 or 120 proceeds when the wait expires. Neither number
  is rejected just because it is absent from the seeded customer records.
- If a later fragment extends an already admitted number, `new_caller_text`
  contains the reconstructed request, rather than only “four”. The full history
  and the actually handled prefix remain available to the classifier. A further
  partial extension, such as “twenty” after an admitted 100, settles again.
- The prompt explicitly preserves the requested operation during an order-number
  correction: an items request remains an items request unless the caller changes
  the operation. Confidence thresholds remain unchanged.
- If the correction's delegation is already pending when a task is superseded,
  the policy schedules one 1 ms delegation recheck. Its next snapshot associates
  that delegation with the new revision. Parlora deliberately forbids association
  and revision of the same task in one batch. Previously, without later speech,
  the delegation could remain pending even after the corrected result arrived.

The numeric delay is a bounded heuristic, not an authoritative end-of-turn signal.
A pause longer than it can still admit 120 before the caller continues to 124.
The late-completion path handles that case instead of asking for an already
provided number. Audio transport, playback, and model turn-taking are unchanged.

## Verification

- **Six new offline regressions** cover numeric admission, legitimate 100/120
  requests, continued prefixes, completion after a finished prefix lookup,
  another partial extension after that lookup, and genuine uncertainty progressing
  to clarification. Session tests require the corrected items result, expected
  job counts, no extra question, settled interpretation, and claimed delegations.
- The original controlled replay, using **real TypeSafe and Jido**, now returns
  “Order 124 contains 1 Desk lamp.” after the deliberately admitted 120 result.
  It finishes **settled**, with both delegations claimed and no clarification.
  [Trace](fixed-sequence-trace.json), [status and result](fixed-sequence-status.json).
  This verifies the worst-case late completion; it deliberately waits for 120
  to complete before sending “four”.
- All eight existing live classifier boundary checks also pass with the final
  prompt: fresh status lookups, missing number, number reply, running/completed
  follow-ups, items follow-up, and order correction.
  [Results](fixed-classifier-regressions.json).
- **Live internal-browser interruption:** the original items and interruption
  recordings traversed WebRTC, GPT-Live, TypeSafe, and Jido. The second clip was
  started during assistant speech, with the audio element playing. The assistant
  answered “order one twenty four has one desk lamp.” There were two completed,
  accepted jobs, both delegations claimed, and interpretation settled. No number
  clarification occurred. [Browser evidence](fixed-browser-replay.json).
- Consumer formatting, compilation with warnings as errors, and **45 tests** pass
  on macOS and Linux with Elixir 1.20.4 / Erlang 29.0.6. The first Linux run exposed
  asynchronous cleanup overlap between cases. New-test teardown and the existing
  idle-application check now wait up to five seconds for session supervision to
  finish, failing if sessions remain. The same seed then passed on both platforms.
- Parlora's macOS `mix ci` passed: **113 tests**, three separately tagged tests
  excluded, native checks, Credo/ex_slop, ex_dna, Credence, and Dialyzer.

The browser result was collected before the additional guard for “twenty” after
an already admitted 100 and the final prompt clarification describing reconstructed
input. The guard has its own offline regression; the controlled late-completion
replay and eight live boundary checks were rerun with the final prompt.
The existing isolated app on port 4001 was restarted afterward with all changes.
The standalone consumer and maintained fixture contain matching application code.

The live check used recorded speech and proves interpretation/task behavior, not
human acoustic quality. Existing capture-discard and playback-starvation events
are present in its diagnostics; this is not a glitch-free audio claim. Physical
Linux audio and another disconnect/persistence run were outside this fix's scope.
