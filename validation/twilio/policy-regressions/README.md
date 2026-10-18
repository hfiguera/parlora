# Phone conversation regressions — 2026-09-18

A manual call completed cleanly but exposed application interpretation issues:
a delivery-instruction query was treated as an edit, “left in the front desk” was
not extracted, a partial “Leave it at” created a draft, and social replies reopened
clarification. The caller's browser also used a different demo identity, so a
successful browser save did not notify the phone session.

The application fixes separate instruction reads from edits, wait for stable
literal edits, reject dangling destinations, give the classifier the latest
caller segment, and treat complete social replies as no new work. TypeSafe's
0.8 confidence requirement is unchanged; a no-work intent does not require an
order target. In a phone launch, the private review listener consistently adopts
the phone actor for root, review and API requests; ordinary browser launches
retain separate identities. Origin/CSRF checks and explicit confirmation remain.

## Evidence

- macOS: 70 consumer tests passed; formatting passed.
- Linux: 70 consumer tests passed using Elixir 1.20.4 / OTP 29.0.6; formatting and
  compilation with warnings as errors passed.
- New regressions verify fragmented draft admission, no premature database
  proposal, social replies after pending recovery, target-independent no-work
  confidence, read-only instruction lookup, and browser confirmation delivery
  to a live session after root navigation with an old cookie.
- Real TypeSafe check: all 8 cases in `final.json` passed. `first.json` preserves
  an earlier 7/8 run: “Thanks, but check order 124” was below the intent confidence
  threshold. The prompt now explicitly distinguishes politeness plus a request
  from social-only input; it does not lower the threshold.
- An initial full-suite test exposed a test synchronization error: the review
  notification test awaited any adapter's `ready` event. It now awaits the
  session's readiness before confirming the draft. Both full suites pass.

These are application regressions plus live classifier checks, not a new live
Twilio audio acceptance run. The diagnostic phone app was restarted for manual
retesting. The earlier human conversation report remains local, outside Git.
A 600 ms unchanged-input window reduces premature draft admission; it cannot
establish an authoritative speech boundary or rule out later corrections.

Reproduce the bounded live classifier check from the standalone consumer:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/twilio/policy-regressions/check.exs
```

This makes eight read-only classifier requests using the existing Keychain
launcher. It prints the judgments and exits nonzero if any expectation fails.
It does not dial a phone number or create a GPT-Live session.
