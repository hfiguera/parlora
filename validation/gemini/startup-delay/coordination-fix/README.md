# Clarification coordination repair

The preceding [API investigation](../api-contract-investigation/README.md)
identified a local clarification collision and independently reproducible remote
pauses. This change repairs coordination and adds non-disruptive delay reporting;
it does not claim to repair Google's internal processing delays.

The same [fixed-judgment reproduction](../clarification_overlap.exs) now returns
`wait_for_context` with no timer, after observing Gemini's captioned question.
The original pre-fix output remains in the investigation directory. The new
regression test covers the same conversation, split caption fragments, subsequent
caller input, declarative captions, and the existing OpenAI behavior.

Library tests cover deferral during speech, fresh re-evaluation without queueing
an obsolete question, deduplication, rejection without a fictional question
boundary, stale response timers, notification without socket writes, late replies,
backend delegation, result submission, and shutdown. Browser tests verify the
notification wire fields and that the notice leaves the call open for late replies.

Validation on macOS and Linux:

- Library `mix ci`: 283 tests/properties passed, three stability tests excluded;
  native tests, formatting, Credo, duplicate detection, Credence, and Dialyzer passed.
- OrderDesk: 174 tests passed on each platform, including correction, clarification,
  saved-announcement, stale-result, and existing provider regressions.
- Additional browser notification signaling regression and JavaScript notification
  test passed; caption/task-scenario JavaScript checks passed (six tests).
- [Bounded live adapter test](live-adapter.json), synthetic 24 kHz PCM: one tool
  request, one result submission, correct order 124 reply, 114,722 output audio
  bytes, no failures. Result submission to first assistant caption: 564 ms.
  Session finished in 9.281 seconds. This is normal-path evidence, not a repeated
  human-call latency qualification or proof that intermittent pauses are gone.

No human audio recording was enabled. Credentials were loaded privately through
the existing Keychain launcher. No automatic re-prompts, replayed jobs, or business
writes are used to recover from a delay. Captioned question punctuation is a
conservative coordination cue; it does not prove playback or cover every paraphrase.
