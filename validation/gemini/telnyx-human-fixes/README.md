# Gemini Telnyx human-call regressions — September 24, 2026

The first handset call completed five backend jobs, but exposed a browser save
failure, competing clarification and an incomplete delivery draft. The source
caption for the draft was “Okay, let's to change the delivery instructions. Put
there left in my front”; no missing word was present in the retained transcript.
No human microphone recording was made. Call metadata was retained locally under
`/tmp/parlora-gemini-telnyx-human-20260924/`.

## Confirmed failures and changes

1. **Cross-port session collision.** Both local processes used the `order_desk`
   cookie with different signing secrets. Cookies do not distinguish localhost
   ports. Polling the browser dashboard replaced the phone review session, causing
   the next confirmation's CSRF token to fail. The [before probe](cookie-before.json)
   used a deliberately nonexistent proposal: valid authentication reached the
   business layer (409/not_found), interleaved dashboard polling changed it to
   403/Request rejected, and refreshing the phone session restored 409/not_found.
   No business record was modified by the probe.

   The cookie name now includes the configured listener origin's port, retaining
   signing, HttpOnly, SameSite, origin checking and CSRF validation. A regression
   simulates two processes' signing secrets and a shared cookie jar, confirms a
   real isolated test draft, checks both identities/tokens survive, checks retry
   idempotency, and verifies wrong-origin/wrong-token requests remain forbidden.
   After restarting the Telnyx server, [ten live HTTP probes](cookie-after.json)
   interleaved both running dashboards without changing the phone token. All ten
   reached the business layer; an invalid token still returned 403. The older
   browser process remained running with its old cookie name; the new phone
   cookie coexists with it. The regression test covers both processes upgraded.

2. **Declarative clarification requests.** Gemini said “I need a three-digit order
   number” and later “I'm sorry, that order number is too long. I need a three-digit
   order number to look up your status.” The previous coordination rule only
   recognized a trailing question mark. The application therefore issued a second
   clarification after speech ended. Bounded English request forms now suppress
   competing clarification until new caller input. Only the final sentence
   qualifies; ordinary facts and quoted/embedded requests do not match. Browser
   review/Confirm prompts are covered too. This is a caption coordination cue,
   not a general semantic classifier, proof of hearing, or business authority.
   OpenAI retains its existing behavior.

3. **Incomplete destination admission.** Literal extraction accepted “left in my
   front” as a complete instruction. Destinations ending in possessive
   `my/your front/back/side` now follow the existing missing-wording clarification
   path instead of creating a draft. A regression verifies no draft is admitted,
   and the complete “left in my front door” subsequently produces the exact
   literal draft. Valid “at the front” and “in my front garden” remain supported.
   This narrow guard does not complete or rewrite ASR text.

The three new failure regressions failed against the previous implementation
(403 on confirmation, repeated clarification, and incomplete literal admission).
The focused suite passed all 20 tests after the changes.

## Verification

| Check | macOS | Linux |
| --- | --- | --- |
| Complete OrderDesk suite | [181 passed](macos-orderdesk.log) | [181 passed](linux-orderdesk.log) |
| Repository `mix ci` | [passed](macos-ci.log) | [passed](linux-ci.log) |

Repository checks include 288 tests/properties (three existing stability exclusions),
native tests, format, Credo, clone detection, Credence and Dialyzer. Application
source and tests were synchronized into standalone consumers. No credential or
microphone recording is included in these artifacts.

## Limits and retest

The initial call's first greeting was interrupted, and provider captions contained
`1123`, `123123`, Spanish fragments, and unfinished text. The fixes above do not
establish the cause of that recognition or interruption behavior. Invalid IDs
remain rejected; no substring is silently selected as the caller's order.
Audio/VAD configuration is unchanged. A new human phone call is still needed to
assess the live conversation after these application fixes. Previously observed
intermittent remote Gemini delays are not claimed resolved.

The phone server was restarted with Gemini selected and the review page refreshed.
The existing isolated database was preserved; the failed draft was not saved.
New phone sessions use a fresh demo review actor after restart, as before.

### Routing cleanup exception

While renewing the test window, the original routing lease exited with
`Telnyx request failed; remote outcome may be uncertain` during restoration. A
subsequent lease restored its own baseline successfully, but a read-only API
check showed that baseline was still the current test tunnel. Therefore original
pre-test routing restoration is **not verified**. No routing lease remains active;
the development number still points to the running Gemini/Telnyx test server and
tunnel. Keep those running for the next test, and reconcile the prior route before
claiming account cleanup. This is an operational API failure, separate from the
passing application regressions above.
