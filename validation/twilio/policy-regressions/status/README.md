# Delivery status versus lookup progress

The caller asked “Okay, and what is the status?” after the items result for order
124. GPT-Live answered from the previously supplied result, but the application
subsequently requested clarification. The original call did not retain the raw
classifier judgment. `before.json` is a reconstructed-context reproduction:
TypeSafe split probability between `status` (0.66) and `followup` (0.34), while
target 124 was confident (0.96). The unchanged 0.8 threshold sent that intent
ambiguity through the bounded recovery path.

The classifier now uses distinct semantic choices: `order_status` for parcel
facts, and `lookup_progress` for the assistant's work. The application's stated
convention makes an unqualified status question refer to the current order.
Progress questions explicitly inherit the current task's order. Candidate
labels distinguish current context from historical mentions. These normalize to
existing policy operations; confidence thresholds and write controls are unchanged.

Evidence:

- Final consumer suites: 72/72 tests passed on both macOS and Linux with the
  pinned toolchain; formatting and compilation checks passed. The same seed
  (405393) reran a Linux failure caused by the phone-review test returning before
  asynchronous session cleanup. Its teardown now waits for session termination
  and removal from the admission gate before the next test.

- `final.json`: 8/8 focused live classifier checks passed, including the failing
  question with/without previous status work, explicit delivery status, three
  genuine progress questions, and a missing new target.
- `earlier-cases-final.json`: the previous 8/8 instruction/social/draft classifier
  checks passed after this change.
- `first-fix.json` preserves an interim run that resolved status intent but
  exposed progress target ambiguity. `earlier-cases-interim.json` preserves the
  saved-instructions target regression found by the broader checks. Explicit
  target guidance and candidate provenance address both.
- The missing-new-target check accepts either a confident unknown target or
  an uncertain judgment with an unknown target: both require clarification and
  must not borrow 123/124 from history.
- Consumer tests cover status → items → status with an assistant answer before
  delegation, late status delegation, genuine progress during running work,
  and rejection of low intent/target confidence.

Run the live check from the standalone consumer with the documented Keychain
wrapper (eight requests; no phone call):

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=:memory: \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/twilio/policy-regressions/status/check.exs
```

This evidence is deterministic application tests plus live TypeSafe checks, not
an additional end-to-end phone call or a guarantee of every future model output.
