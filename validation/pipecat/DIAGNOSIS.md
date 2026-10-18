# Caption follow-up investigation — 2026-09-22

The number example is a reproducible GPT-Live caption recognition error plus a
separate numeric-formatting penalty in our scorer. The original missing-caption
failure did not reproduce; its exact cause remains unproven.

These diagnostics are separate from the published baseline. Original attempts,
coverage, and WER are unchanged.

The evaluation tools now implement the recommended follow-ups: see the
[numeric scoring and capture instructions](README.md#numeric-meaning-alongside-strict-wer).
The investigation below describes the original evidence and conclusions.

## Number mismatches: two distinct causes

Sample `3a7a85ed-a140-20ac-59f1-f3e45fe68837` contains the reference phrase
“7-day meal plan.” Both original evaluations recorded a literal `" 70"` provider
caption delta. This was not created by joining caption fragments or by scoring.

| Diagnostic | Result for “7-day” |
| --- | --- |
| Original pilot and full run through Parlora | Incorrect in 2/2 attempts |
| New instrumented Parlora runs | Incorrect in 3/3: “70,” “seventy,” “70” |
| Direct WebSocket calls, bypassing Parlora | Incorrect in 2/3; correct in 1/3 |
| Whisper-1 file transcription, original and resampled audio | Correct in 2/2 |
| GPT-4o-transcribe file transcription, original and resampled audio | Correct in 2/2 |

The direct calls use the same GPT-Live model alias, instructions, audio format,
voice, and real-time 20 ms input pacing. They send the exact prepared PCM without
Parlora's queues, pacing, or event translation. The live diagnostics observe
12 seconds of trailing silence; waiting longer did not correct the wrong phrase.
No reference transcript or expected number was included in any API prompt.

**Conclusion:** the error occurs in the provider's streaming caption output.
Parlora is not a necessary cause: the provider makes the same error when bypassing
it. The independent transcription comparisons support “7-day” and argue against
resampling being responsible. The acoustic/decoder mechanism inside GPT-Live is
not observable here; “seven-day” being confused with “seventy” is a plausible
interpretation, not a proven internal mechanism. Caption errors alone do not
establish that the conversational model misunderstood the request.

The same sample also exposes a **measurement limitation**, not a changed number:

| Reference | Caption | Strict scorer tokens | Edit count |
| --- | --- | --- | --- |
| 7-day | 70 | `7 day` → `70` | 2 |
| 2,000 | 2000 | `2 000` → `2000` | 2 |
| 2,000 | two thousand | `2 000` → `two thousand` | 2 |

`score.py:words` splits punctuation and deliberately does not normalize number
meanings. In the original full-run example, two of the four edits reflect the
wrong “7-day” phrase and two reflect equivalent calorie formatting. Other corpus
examples include digit strings versus spoken digits and clock times with or
without `:00`. Raw WER mixes these differences with actual recognition errors.
This is consistent with the declared scoring policy, but raw WER alone is
insufficient to assess numeric entity accuracy.

**Action justified by the evidence:** keep strict WER and add a separately labeled
numeric-entity score with explicit handling of quantities, units, dates, times,
ordinals, and identifiers. Keep “7-day” versus “70” as an error. Do not introduce
a blanket caption replacement: “70” can be correct in other requests. This study
does not establish that replacing the live provider with file transcription
would improve the product's latency or task success.

## Missing caption: original cause remains unresolved

Sample `1a9823e0-ef24-71eb-cb3a-fc50f6bb8f52` has 3.03 seconds of audio.
The original session had no collected caption, normal finalized closure, and
2.724 ms maximum injection lateness. Its PCM was nonzero and checksum-verified.

| Retry condition | Captions observed |
| --- | --- |
| Parlora, 12-second trailing silence, sequential sessions | 3/3 |
| Direct provider, 12-second trailing silence | 3/3 |
| Parlora, original 3-second tail and concurrency 8 | 8/8 |

All **14/14 retries** produced captions within the original 6.03-second deadline.
First captions arrived 0.954–1.899 seconds after input began; the latest final
observed caption in these retries arrived at 4.149 seconds. Longer waits did not
reveal a reproducible delayed-caption problem. The eight short-tail sessions all
closed with confirmed finalization and cleanup.

Instrumented Parlora retries retained raw server events before protocol
translation and the outbound PCM before WebSocket encoding. Every source audio
chunk was present in order, and every raw input caption matched the application
caption in text and provider offsets. There were no unexplained caption event
types in these captures. Maximum injection lateness across all 20 live diagnostic
sessions was 8.974 ms.

Parlora's provider sends 10 ms of silence when its input queue is empty. The wire
captures show 60–70 ms of leading silence and, in some attempts, a single 10 ms
silence insertion near the beginning of the clip. No source chunks were lost.
Those insertions were present in successful caption retries, and the number error
also occurred without them. They are an observed transport difference, not an
established explanation for either original failure.

The reference wording itself needs human review: it says “volunteer,” while
Whisper-1 consistently returned “bottom tier” on both source and resampled audio,
and other transcribers returned several variants. This is evidence of uncertain
reference/recognition quality, **not evidence explaining the absent caption**.
No human listening judgment was performed in this investigation.

**What remains unknown:** the original runner retained translated caption events,
not raw provider messages or actual outbound audio. It also stopped collecting
captions at the deadline and discarded events while awaiting closure. Consequently
we cannot retrospectively distinguish a provider omission, an unusually delayed
caption, an unhandled raw event, or an intermittent delivery problem in that
attempt. The retries do not support a deterministic audio corruption, translation,
or three-second-window bug, but they cannot rule out an intermittent one. Calling
this a confirmed provider failure would exceed the evidence.

**Action justified by the evidence:** retain bounded, opt-in diagnostic captures
for future missing-caption attempts, including audio delivery, raw event types,
caption timing, and events during closure. Continue counting the original failure;
do not silently retry it into a passing coverage result. No production fix is
justified solely by this non-reproducing attempt.

## Evidence and reproduction

Investigation used commit `8a5c5bf`, the existing pinned dataset and PCM checksums,
20 fresh GPT-Live sessions, and eight independent file-transcription calls.
The provider model alias does not establish an immutable model snapshot.
All completed Parlora batches reported zero active session supervisors; all direct
sessions received `session.closed`.

The tracked [diagnostic summary](diagnostic-summary.json) records trial timings,
audio-integrity checks, numeric outcomes, and SHA-256 hashes of local evidence.
Raw audio, full provider responses, and exact experiment scripts remain ignored
under `runs/root-cause-20260922/`:

- `probe.exs`: compiles a renamed copy of the production provider with observation
  hooks immediately before JSON transmission and before raw event translation.
  It also compiles a copy of the evaluation runner with a 12-second tail and a
  longer guard timeout. Production files are untouched. Each string patch asserts
  a unique match; exact instrumented sources are saved.
- `probe-3s.exs`: the same instrumentation with eight concurrent missing-clip
  trials; set `PROBE_TAIL_MS=3000` when running it.
- `direct.py`: independent Python WebSocket client with no Parlora code, three
  repetitions of each clip, 12-second tail, and raw event capture.
- `asr.py`: source audio decoded to 16 kHz WAV and the prepared 24 kHz PCM wrapped
  as WAV; both submitted to `whisper-1` and `gpt-4o-transcribe`, without a reference
  prompt, using the [file-transcription API](https://developers.openai.com/api/docs/guides/speech-to-text).

Use fresh output directories for reproductions; these scripts intentionally do
not overwrite trial directories. Run the Elixir probes with `MIX_ENV=test`, the
existing `scripts/with_keychain.py` helper, and `mix run`; run Python probes through
the same credential helper and `uv run --python 3.12`. Python output paths are
fixed in the archived scripts and must be changed for a new run. Credentials and
authorization headers are not captured.
