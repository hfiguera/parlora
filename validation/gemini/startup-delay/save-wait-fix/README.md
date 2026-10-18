# Save-wait coordination and response deadline

The 19:46–19:47 test call saved order 124 at 19:46:42. Its first announcement was
submitted at 19:46:50.472, retried at 19:46:56.532, and followed by application
clarification at 19:47:01.304. Caller captions arrived between those commands.
Reply audio started at 19:47:09.310. Re-arming the response watch on each command
and caption prevented its 12-second deadline from firing. This explains the
missing warning, not Google's internal reason for delaying the response.

Changes:

- Keep the earliest response deadline until actual assistant caption/audio or a
  new delegation demonstrates progress. Further submissions and caller captions
  also cannot clear an already displayed delay notice. Stale deadlines remain inert.
- Submit a Gemini browser-save announcement once per version; retain the existing
  bounded OpenAI retry behavior.
- Publish an expiring application-context clarification hold while an announcement
  is pending. The policy suppresses only competing clarification and schedules
  fresh interpretation at expiry. Corrections and understood work remain eligible.
  Matching caption evidence clears the hold early; worker loss cannot make it
  permanent because the policy checks its absolute monotonic deadline.
- Continue recognizing matching late save captions after the notification deadline,
  retaining only the latest submitted save for each of at most eight orders. A
  newer destination invalidates the old candidate. No database write is retried.

Regression evidence uses a local WebSocket peer and fixed application judgments;
these are deterministic sequence tests, not claims about new human-call behavior.
They cover repeated outbound messages/caller captions, one delay notice, recovery
on late output, single save submission, bounded clarification, late confirmation,
newer-save protection, and the unchanged OpenAI retry test.

macOS and Linux library `mix ci` passed: 285 tests/properties each, three stability
tests excluded, plus native tests, formatting, Credo, duplicate detection, Credence
and Dialyzer. macOS OrderDesk passed 177 tests. The initial concurrent Linux run
passed 176/177; the pre-existing GreetingTest timed out waiting 100 ms for its
subscriber process. All six greeting tests passed in isolation; the full suite
was rerun with the original seed (54992) after the library checks completed:
177/177 passed.

A [bounded live adapter lookup](live-adapter.json), using existing synthetic PCM,
passed: one tool call, one result submission, correct order 124 response, 116,160
output audio bytes, and no failures. Submission to first assistant caption was
766 ms; total session duration was 9.621 seconds. It confirms the normal adapter
path and does not establish that intermittent Gemini service delays are fixed.
No human audio recording was enabled; credentials stayed in process memory via
the existing private Keychain launcher.
