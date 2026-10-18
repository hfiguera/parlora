# Browser-action acknowledgment regression — 2026-09-18

## Finding

The manual Telnyx call saved order 124's delivery text through the browser, then
“I think I did” was followed by an unnecessary `clarification_requested` event.
GPT-Live had already received the verified save notification and correctly said
“It’s updated.” The original call did not retain raw TypeSafe judgments.

`before.json` is a reconstructed, read-only classifier replay, not the original
call’s probability trace. With an applied draft, TypeSafe selected `none` at 0.67;
the unchanged 0.8 intent threshold made it uncertain, and the policy’s final
recovery phase emitted clarification. The same happened with a pending draft.
The generic question also incorrectly claimed “No order changes were made.”

## Change

The application classifier explicitly distinguishes statements acknowledging a
page action from questions asking to verify a save. A statement is `none` for
pending and applied drafts alike; it never proves or authorizes a save. Questions
remain `instructions` database reads. Requests, corrections and refusals in the
same segment still take precedence. Confidence and browser authorization checks
are unchanged. Generic clarification/error wording makes no claim about earlier
browser writes.

## Validation

- `after.json`: all 10 live TypeSafe classifier cases passed with the selected
  jev-1.13.0 model. The reported phrase classified as `none` at 1.0 for both
  applied and pending drafts. Verification questions, new lookups, correction
  and refusal stayed distinct. These are model observations, not guarantees.
- `check.exs`: bounded replay using reconstructed context plus policy decisions.
  It checks acknowledgments create no work and verification questions dispatch
  reads. Correction admission still uses the existing delivery-settling stage.
- `browser_acknowledgment_test.exs`: offline session tests feed the recorded
  answer shape through the real policy, Jido and SQLite, for pending and applied
  drafts. No extra job, clarification, save or version change occurs; a late
  delegation associates; a later verification question still reads saved data.
  A separate test retains clarification for low-confidence `none` and checks
  that fallback/error wording cannot deny a prior save.
- macOS: **89 consumer tests passed**, format check passed.
- Linux: **89 consumer tests passed**, format check passed.
- The previous six-case ambiguous-follow-up classifier replay also passed with
  the updated prompt. Library/native code was unchanged.

Run from the consumer project with an isolated database:

```sh
ORDER_DESK_DATABASE=:memory: ORDER_DESK_TYPESAFE=1 \
  python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/telnyx/policy-regressions/browser-acknowledgment/check.exs
```

The launcher reads the existing Keychain secret into the child environment.
The replay does not start phone calls, save orders, or access the manual-call
SQLite database. No new handset/audio retest is claimed by these checks.
