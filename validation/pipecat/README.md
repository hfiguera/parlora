# Public Pipecat speech evaluation

See [the pilot and full-corpus results](RESULTS.md) for the September 22 evaluation.

Evaluates the input-caption path through a real Parlora session and GPT-Live-1.
This validation fixture can opt into bounded capture in the built-in provider;
capture is disabled for ordinary application sessions.
It uses only [Pipecat's public STT dataset](https://huggingface.co/datasets/pipecat-ai/stt-benchmark-data),
pinned to `3fe50170d520c951957b86996ef082a6ab87b394`. No Ocular inputs are used.

The 1,000 clips originate from Pipecat's smart-turn corpus, not FLEURS. Pipecat
describes the references as Gemini-generated and human-reviewed. The pinned
dataset card does not declare an explicit dataset license. Public availability
does not establish redistribution or training rights: downloaded audio, reference
transcripts and full reports stay in ignored local directories. The benchmark
code's license must not be assumed to license its source audio.

## Prepare and validate offline

Requires the repository's pinned Elixir/OTP toolchain, `uv`, Python 3.12 and FFmpeg.
Preparation downloads a 298 MB Parquet file, verifies its pinned SHA-256, validates
all 1,000 rows, and creates mono signed PCM16LE at 24 kHz for Parlora. Source bytes
and derivative hashes are retained. Preparation does not call any AI service.

```sh
uv run --python 3.12 validation/pipecat/prepare.py
python3 -m unittest discover -s validation/pipecat -p 'test_*.py'
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  mix run validation/pipecat/self_test.exs
```

The self-test uses synthetic silence and a scripted caption through real session
and pipeline code. It checks pacing, byte accounting, caption collection and
cleanup. It is never included in dataset accuracy results.

## Live pilot, then full corpus

Live commands make billable provider requests. The macOS helper retrieves the
existing development credential without printing it. Alternatively provide
`OPENAI_API_KEY` in the environment and omit the helper. No microphone, speaker,
browser, phone account, application database or TypeSafe service is used.

```sh
mkdir -p validation/pipecat/runs
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  python3 scripts/with_keychain.py mix run validation/pipecat/run.exs \
  --live --manifest validation/pipecat/.cache/manifest.json \
  --output validation/pipecat/runs/pilot --limit 20 --concurrency 4 --diagnostics missing
python3 validation/pipecat/score.py validation/pipecat/.cache/manifest.json \
  validation/pipecat/runs/pilot --numeric
```

The first 20 IDs in a stable hash-based ordering are the pilot. Inspect its report
and worst errors before expanding. The initial sanity gate requires every planned
clip to complete, no missing transcripts, no remaining session supervisors, maximum
input injection lateness of 100 ms, and pooled word error rate at the three-second
observation deadline no greater than 25%. This deliberately broad threshold checks
basic viability; it is not a product accuracy target or a statistical guarantee.

After the pilot passes, use a fresh output directory:

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  python3 scripts/with_keychain.py mix run validation/pipecat/run.exs \
  --live --manifest validation/pipecat/.cache/manifest.json \
  --output validation/pipecat/runs/full --limit 1000 --concurrency 8 --diagnostics missing
python3 validation/pipecat/score.py validation/pipecat/.cache/manifest.json \
  validation/pipecat/runs/full --numeric
```

Existing output directories are refused. There are no automatic retries. A failed
group stops new admissions, leaving completed attempt files available for scoring.
The scorer keeps every planned reference in the denominator, including unattempted
clips. The complete corpus includes the pilot IDs; it is not an independent
held-out evaluation. Preserve these manifests and use separate data for tuning.

### Continuing an interrupted run

After resolving the external failure, start in a new output directory and pass
`--skip-successes-from` for each prior run whose completed clips should be reused.
The runner verifies the manifest and listening configuration, and records hashes
of preserved results. Failed attempts stay in their original directory. Retrying
those clips is an explicit continuation, not a rewritten first-pass success.

```sh
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' MIX_ENV=test \
  python3 scripts/with_keychain.py mix run validation/pipecat/run.exs \
  --live --manifest validation/pipecat/.cache/manifest.json \
  --output validation/pipecat/runs/continued --limit 1000 --concurrency 8 --diagnostics missing \
  --skip-successes-from validation/pipecat/runs/full
python3 validation/pipecat/score.py validation/pipecat/.cache/manifest.json \
  validation/pipecat/runs/continued --include-preserved --numeric
```

Without `--numeric`, recovered coverage gets `score-recovered.json`; with it,
`score-numeric-recovered.json`. The original first-pass report remains separate. Supply every relevant prior directory on further continuations.
The later runner also retains sanitized startup rejection details and snapshots
its own source in the run directory. These changes do not change input pacing,
instructions, or caption scoring.
Later close-event failures also retain already observed transcript fragments and
sanitized failure details. Manifests are copied into run directories for offline
rescoring. Use the original prepared cache manifest for subsequent live runs,
because its audio paths resolve relative to the cache directory.

## Numeric meaning alongside strict WER

`score.py --numeric` writes `score-numeric.json` (or
`score-numeric-recovered.json` with `--include-preserved`). It includes the original
strict WER and gate plus a separate, versioned numeric-entity assessment at the
three-second deadline. It never overwrites `score.json` or `score-recovered.json`.
Omit `--numeric` for the original report format.

The deterministic English rules equate clear formatting differences such as
`2,000` / `2000` / `two thousand`, `50%` / `fifty percent`, and `8:00 am` /
`eight a.m.`. Values, recognized units, signs, ordinals, AM/PM, and identifier digit
order/leading zeros remain significant. `7-day` / `70` remains an error. Named
month dates and ISO dates are supported, and identifier context includes phone,
order, tracking, extension, and account numbers. Unit conversion is not performed.

Each clip lists extracted reference/hypothesis entities, edit count, and review
reasons. Ambiguous adjacent numbers, fractions, and slash dates are flagged; there
is no guessed date order or blanket removal of numeric differences. The automatic
entity error rate is pooled entity edits divided by reference entities in the
review-free subset. Missing/failed attempts retain their reference entities;
extra numbers are insertions. A zero denominator produces `null`, not a passing
score. Review-required clips stay visible and are excluded from that automatic
metric, so read its review count and coverage alongside its rate.

This is a conservative formatting comparison, not a complete semantic parser.
Unrecognized languages, units, colloquial numbers, and context-sensitive uses of
words such as “one” can need human review even when not automatically flagged.
Entity order is compared, but association with a particular item and surrounding
intent/negation are not evaluated. These scores do not change the pilot gate.
See [the offline numeric results](numeric-results-summary.json) for the saved
corpus; this is a new measurement of existing captions, not a model improvement.

## Capture evidence for missing captions

The live commands above include `--diagnostics missing`. The CLI default is `off`;
`all` retains evidence for every attempt when investigating a specific case.
Capture changes neither prompts nor audio pacing and does not enable retries.

With `missing`, each provider session temporarily holds bounded evidence and
retains it only for failures, invalid attempts, or no nonempty caption by the
original deadline. Successful attempts discard their diagnostic audio. Files are
saved under `RUN/diagnostics/SAMPLE_ID/` in the existing ignored `runs/` tree:

- `wire.pcm`: mono PCM16LE at 24 kHz handed to the WebSocket transport, including
  automatically inserted silence. This is not proof of server receipt.
- `capture.json`: input acceptance byte count/SHA-256, expected input+tail digest,
  outbound audio digest/count, raw server event types and field names before
  protocol translation, bounded caller-caption deltas/offsets, timing origins,
  provider error codes, and captions observed during closure.

`close.late_events` in the attempt result retains captions arriving after collection
stops. They are diagnostic evidence only; the scorer still uses on-time `events`.
Compare `input_started_at_us` with `origin_us + event.at_us` to align wire events
with clip injection. The run snapshots the provider and capture source with hashes.

Per session, capture retains at most 2,000,000 audio bytes, 4,000 event records within a
1,000,000-byte serialized-record budget, and 262,144 bytes of caption text. Truncation/omission is explicit. Diagnostic
directories are mode `0700` and files `0600`; no authorization headers, API keys,
instructions, assistant audio, or arbitrary error-message bodies are retained.
Caller audio/captions are sensitive and remain local. The provider option is
`diagnostic_sink: pid`; ordinary sessions omit it and capture nothing.

If the provider dies without being able to send its final capture (for example,
an uncatchable process kill), the result reports `diagnostics.state: unavailable`.
Other possible states are `retained` and `discarded_success`; unavailable evidence
must not be treated as proof that no audio or captions existed.

## What is measured

- Each clip gets a fresh session with fixed English listening instructions. Only
  audio reaches the provider: reference transcripts and sample labels do not.
- A memory channel queues real PCM into production `Parlora.AudioPipeline` and
  the built-in provider adapter. Input is paced in 20 ms frames against absolute
  monotonic deadlines, followed by three seconds of silence. Late injection above
  100 ms invalidates the attempt. This checks harness injection, not network arrival.
- Generated assistant output is suppressed and drained, without acoustic feedback.
  A no-action policy prevents backend work. This is a listening/caption baseline,
  not the OrderDesk conversational prompt or task workflow.
- User transcript deltas retain observation times and provider offsets. Scoring
  concatenates deltas available by nominal **clip end + 0/250/500/1000/3000 ms**.
  Clip end is not an annotated speech boundary. Leading/trailing silence varies.
  Parlora exposes no final-caption event: no final-transcript latency is claimed.
- Word error rate is pooled edit distance divided by total reference words.
  Normalization applies Unicode NFKC, lowercase and punctuation tokenization;
  apostrophes and digits remain. It does not equate `124` with `one twenty four`
  or forgive paraphrases. The optional numeric score interprets a supported subset
  of numeric formatting separately and flags uncertain forms for review.
- First-text p50/p95 is relative to clip injection start and includes source silence.
  Failures, missing transcripts, cleanup, source hashes, instructions and requested
  model are recorded. A fixed provider model snapshot is not guaranteed.

Reports do not establish browser/Opus or telephony quality, interruption handling,
order selection, authorization, audible response latency, or playback continuity.
They are not directly comparable with Cekura or Pipecat leaderboard numbers:
provider behavior, normalization, endpoint definitions and observation windows differ.
The useful comparison is this same frozen evaluation before and after a Parlora
change, with failures investigated and promoted to focused regression cases.
