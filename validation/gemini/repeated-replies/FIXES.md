# Repeated-reply repairs and verification

2026-09-24. The preceding [diagnosis](README.md) and `replay.log` describe the
pre-fix implementation. `replay_test.exs` deliberately asserts those old defects;
it is retained as historical reproduction code, not the current acceptance suite.

## Changes

- **Correction delivery:** a supersession can atomically claim the current pending
  delegation. Validation checks both references and rejects stale, already-claimed
  and conflicting targets. The replacement result answers the current call once.
  A late duplicate association carries delivery state to the Gemini adapter, which
  terminates that call using `SILENT` when the result is already submitted or work
  is still pending. New results and rejected-result recovery remain `WHEN_IDLE`.
  Clarification followed by a genuinely new result retains its existing path.
- **Instructions lookup:** status-only summaries no longer preload delivery
  instructions or items. The prompt explicitly requires a fresh instructions
  lookup. This removes the source of the observed early answer in the status →
  instructions sequence. It is a model-behavior mitigation, not a deterministic
  prohibition on every possible early or incorrect model utterance.
- **Save wording:** prompts request an exact quote of the saved text. Verification
  also accepts narrowly defined grammatical equivalents, including the actual
  front-door paraphrase, while preserving order, negation, complete word boundaries,
  destinations, and unrelated preposition differences (in a garage versus at it).
- **Save timing:** Gemini publishes separate speech-state observations. Generation
  completion alone does not end speech, and speech completion does not override
  background work. The save worker additionally waits for a pause in source-audio
  queue/handoff observations. Browser handoffs distinguish source audio from filler
  silence. This is conservative playout timing, not proof of remote playback.
- **OpenAI compatibility:** providers without speech-state observations retain
  the existing caption-pause rule. Continuous OpenAI source silence must not block
  announcements. Its instruction fallback and acknowledgment semantics are intact.
- Development diagnostics now retain speech state and context-submission command
  IDs, without retaining content, arguments, keys, audio or resumption handles.

## Automated verification

| Check | macOS ARM64 | Linux x86_64 |
| --- | --- | --- |
| Root `mix ci` | 278 tests/properties passed; all other checks passed | Same |
| Explicit stability suite, seed 42 | 3 passed | 3 passed |
| Standalone OrderDesk suite | 170 passed | 170 passed |

Root CI includes compilation, formatting, native tests, Credo, zero-clone analysis,
Credence and Dialyzer. The observer's five regressions and 12 JavaScript pilot checks
also passed on macOS. Logs are in [checks](checks/). Relevant regressions cover
atomic correlation and rejected batches, silent duplicate call completion,
separate speech/background state with buffered audio, saved-text equivalence and
negative guards, ongoing playback, filler silence, and OpenAI continuous audio.

The initial app suite exposed old assertions expecting two-phase association;
they now assert atomic correlation instead. The first timing implementation also
incorrectly treated unlabelled local-device silence as active playback; the final
guard uses explicit source handoffs and actual queue observations.

## Bounded live checks

All runs used real providers, TypeSafe, Jido, WebRTC and isolated demo databases
with synthetic caller audio. They did not change the human demo's saved orders.
Every attempt's case data, plans, provider choice, source hashes and result reports
are retained in this directory.

- **Gemini completed correction and instructions:** passed. Spoken rows were:
  `Order 123 has shipped and is expected Friday.`, then exactly one
  `Order 124 is out for delivery.`, then exactly one
  `There are currently no delivery instructions for order 124.` Three backend jobs.
  The scenario waits an additional 6.5 seconds after each relevant answer to catch
  delayed repetition. See [case evidence](gemini-initial/26-completed-correction-once-r1.json).
- **Gemini save during speech:** final run passed. Browser confirmation happened
  while status speech was active. The assistant subsequently said exactly once:
  `For order 124, the instructions "left in my front door" have been saved.`
  The database advanced once and no provider interruption occurred after the
  confirmation boundary. The check observes another eight seconds for repetition.
  See [case evidence](gemini-save/27-front-door-save-once-r1.json).
- **OpenAI slow correction:** passed, including obsolete-result protection and no
  duplicate backend work. See [case evidence](openai-initial/12-correction-r1.json).
- **OpenAI browser confirmation:** final run passed after restoring its original
  caption-pause behavior. The saved reception update was announced with provider
  acknowledgment semantics unchanged. See [case evidence](openai-save/20-browser-confirmation-r1.json).

Two failed evaluations are retained:

1. The first Gemini save assertion counted an earlier caller interruption of the
   greeting as a save interruption. Its events show the save itself waited for
   status speech to finish and was announced once. The final test waits for the
   greeting and explicitly scopes interruption checks to the confirmation boundary.
2. The first OpenAI save test found a real regression in the new timing gate:
   continuous source audio prevented the gate opening. This was fixed, a dedicated
   regression was added, and both full app suites and the live save case passed.

These calls do not establish acoustic quality through speakers, every model
paraphrase, accent coverage, or full provider parity. Arbitrary paraphrases can
still expire as unconfirmed; the verifier intentionally avoids fuzzy destination
matching. Speech and source handoff observations do not prove what a human heard.

## Running demo

The Gemini server at `http://localhost:4000/` was restarted with these changes.
The saved-order rows before and after restart were identical: orders 123 and 124
remain version 3, and order 825 remains version 1. The next call's bounded metadata
will be captured at `/tmp/parlora-gemini-human-repetition-fixed-20260924/metadata.jsonl`.
No changes have been committed in this turn.
