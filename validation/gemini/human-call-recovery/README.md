# Human-call recovery fixes — 2026-09-24

The 16:34–16:37 human call repeatedly clarified order 124 after “No, 123,”
failed to create a draft from “Live with My Neighbor,” and claimed an update was
being processed despite no delivery job being admitted.

## Changes and deterministic evidence

- `Speech.read_correction/1` recognizes complete explicit read corrections and
  retains an understood read operation. Equivalent corrections do not repeat a
  lookup. Unknown new operations and pending writes do not borrow a completed
  read operation. Partial numbers, conflicting IDs and action suffixes are rejected.
- Untimed Gemini input exposes the latest speaker run separately from full
  history. Timed providers retain overlap-aware segmentation, including assistant
  backchannels inside a caller's number. No timestamps or authoritative turns are
  fabricated.
- Literal `Live with my neighbor` is accepted only after delivery classification,
  settling and application admission, and remains literal in the review draft.
  No automatic ASR correction or save permission is inferred.
- Clarification about an existing task also names the pending provider call when
  present. Core validation checks both references and rejects conflicting batches.
  A regression follows the actual decision through Gemini `Calls.context/3` and
  verifies a matching function response with no pending call left behind.
- Missing-wording context explicitly states that no draft exists. Voice guidance
  prohibits treating a tool call as admitted work or a ready draft. This guidance
  mitigates model behavior; it cannot deterministically prevent every false spoken
  progress claim.

Both macOS ARM64 and Linux x86_64 passed root `mix ci`: **274 tests/properties**,
native checks, formatter, Credo, zero-clone budget, Credence and Dialyzer.
The final standalone OrderDesk suites passed **165 tests** on each platform.
JavaScript caption and pilot checks passed **15 tests**. Logs are in [checks](checks/).
Nine focused human-call regressions cover the corrections, unknown operations,
literal destination, input fragments, timed overlap, and clarification correlation.

## Live validation

[Retained evidence](evidence.json) includes every attempt, source hashes, literal
captions, reply checks, final jobs, proposals, and saved orders. Calls used real
Gemini/OpenAI, TypeSafe, Jido, browser WebRTC and fresh SQLite databases with
synthetic Samantha speech, not the user's microphone or saved-order database.

- Gemini's equivalent-124 then “No, 123” scenario passed twice. There were exactly
  two reads, no duplicate equivalent lookup, and the final answer referred to 123.
- The final delivery-recovery scenario passed: read existing instructions, ask for
  missing wording, create a neighbor draft, and speak the browser-review prompt
  after its backend result. No saved orders changed.
- An earlier delivery attempt actually transcribed `Live with my neighbor` and
  created that exact pending draft. The final attempt transcribed `Leave with my
  neighbor` and preserved that wording instead.
- The browser-confirmation scenario passed: one explicit confirmation saved the
  exact draft once and the assistant announced the verified save.
- The OpenAI correction control passed with exactly two reads and the correct
  final order. OpenAI acknowledgment semantics are unchanged.

Two failed test evaluations are retained rather than counted as passes. The first
expected “side door” although the fresh fixture had no saved instructions; Gemini
correctly reported no instructions. The second completed draft creation but the
campaign's generic clear-request guard rejected the intentionally required
clarification. The fixture expectation was corrected and case 25 explicitly
allows clarification; the final run additionally requires the real draft's spoken
browser-review prompt. Business and save-boundary assertions were not relaxed.

The correlated function-response repair is proven deterministically. In the live
missing-wording scenarios Gemini could ask the question without issuing a new
function call, so those calls alone do not establish that wire-level repair.
These bounded synthetic calls do not certify accent coverage, every progress
claim, acoustic playback quality, or production reliability.

The running Gemini app was updated and the internal browser reloaded. The three
saved order records, including both prior version-2 changes, were verified
unchanged across the restart.
