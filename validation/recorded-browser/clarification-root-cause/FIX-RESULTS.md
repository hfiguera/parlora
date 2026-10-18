# Clarification fixes — September 17, 2026

## Changes

- The application defines fresh “check order” requests as status lookups and removes
  `followup` from classifier choices when no active/recent task exists. Follow-ups
  about running and completed work remain supported. The 0.80 probability threshold
  and explicit browser confirmation required for saved changes are unchanged.
- Caller text preserves punctuation and whitespace, but these fragments no longer
  advance the application's meaningful caller revision. They cannot reopen handled
  work or restart a clarification wait. Words, numbers, and other substantive input
  continue through normal interpretation, including ambiguous corrections.
- `Parlora.status/1` now reports pending delegations as unresolved when no policy is
  executing. This changes the previously documented coarse meaning of `settled`;
  the public-interface documentation was updated. Result-delivery gating is unchanged.

## Verification

- Library `mix ci`: **passed on macOS**, including 113 tests (3 opt-in tests excluded),
  native checks, Credo/ex_slop, ex_dna, Credence, and Dialyzer. The final Linux library
  suite also passed **113 tests, 3 excluded**. Linux native/static/Dialyzer checks
  passed during the broader CI runs; the test suite was rerun after fixing the
  test startup races described below.
- Consumer suite: **39 passed on macOS and Linux**, using Elixir 1.20.4 / OTP 29.0.6.
- [Eight live TypeSafe checks](classifier-fix-results.json) all passed: fresh 123/124,
  missing number, number-only reply, running/completed follow-ups, items, and correction.
  Both fresh lookups received status probability **1.0** in this sample. This is a
  bounded regression sample, not a reliability guarantee.
- The formerly failing session replay now remains **settled** with one completed,
  accepted result after a trailing period and 3.5 seconds of observation—longer
  than the normal recovery windows. No clarification was submitted. See
  [status](completed-tail-fixed-status.json) and [trace](completed-tail-fixed-trace.jsonl).
- Live browser status → items: order 124 was reported out for delivery, followed by
  one desk lamp. Two jobs completed/accepted, both delegations claimed, interpretation
  settled; no clarification request.
- Live browser 123 → 124 → 123: final answer was order 123 shipped/expected Friday;
  all delegations claimed and interpretation settled; no clarification request.
  See [captions and status](fixed-browser-replays.json) and
  [classification/decision trace](fixed-browser-classification-trace.json).

The browser correction run also recorded an intermediate lookup for **120** while
“one hundred twenty three” was still arriving, before superseding it with 123. The
final spoken answer was correct. This is a separate remaining streaming-number
limitation, not evidence of perfect intermediate job selection. These fixes address
unnecessary clarification and status reporting; they do not establish word/turn boundaries.

The initial broader Linux CI run exposed an unrelated race in the relay configuration
test: its 150 ms startup deadline could expire before configuration inspection. The
test now inspects configuration before explicitly delivering the timeout message;
the separate test exercising an actual 50 ms negotiation deadline remains unchanged.
A subsequent run hit the substitution test's generic one-second message timeout,
and another hit the same assumption in the example-policy helper, while creating
browser channels on Linux. Browser startup assertions now wait for attachment and
readiness within Parlora's existing 15-second startup budget; they still require both
messages and all the correction, audio, stale-result, and cleanup assertions. No
runtime deadline or assertion about the requested behavior was removed.

All live calls were closed, original test clips restored, and the isolated browser
app reported zero active sessions. The normal app's saved orders were not edited.
Synthetic browser tests do not establish physical microphone behavior, acoustic
smoothness, or physical Linux audio support.

## Re-run the targeted live checks

From the standalone consumer with the pinned toolchain, run either
[verify_classifier_fix.exs](verify_classifier_fix.exs) or
[verify_tail_fix.exs](verify_tail_fix.exs) through the existing credential helper:

```sh
ORDER_DESK_TYPESAFE=1 ORDER_DESK_DATABASE=/tmp/parlora-fix-verification.sqlite3 \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/recorded-browser/clarification-root-cause/verify_tail_fix.exs
```

These scripts make bounded live TypeSafe calls. The tail replay uses a scripted
provider and synthetic local audio, with the real application policy and backend.
It does not open a GPT-Live session or require a microphone.
