# Pipecat evaluation results — September 22, 2026

The 20-clip pilot passed its sanity gate. The complete public corpus was then
evaluated through Parlora's recorded PCM input path and GPT-Live-1, with preserved
results reused after two interruptions. All **1,000 distinct clips** were processed;
**999 produced captions** within the observation window. Recovered full-corpus
word error rate is **3.20%** at nominal clip end plus three seconds.

This establishes a reusable baseline and specific cases to investigate. It does
not demonstrate an accuracy improvement from a production code change. The full
corpus misses the zero-missing-transcript criterion that the smaller pilot passed.

## Results

| Measurement | Pilot | Complete corpus, recovered coverage |
| --- | ---: | ---: |
| Distinct clips processed | 20 | 1,000 |
| Clips with observed captions | 20 | 999 |
| Reference words | 510 | 23,323 |
| Word error rate at clip end + 3 s | 2.75% | **3.20%** |
| First-text latency from clip start, p50 | 2.14 s | 2.06 s |
| First-text latency from clip start, p95 | 3.60 s | 3.60 s |
| Maximum input injection lateness | 11.02 ms | 24.86 ms |
| Active session supervisors after each run | 0 | 0 |

The corpus contains **159.89 minutes** of source audio. The final score counts
746 word edits, including all six reference words from the missing-caption clip.
613 clips have zero errors under the declared tokenizer. First-text percentiles
are conditional on a caption being observed; the missing case is reported separately.

| Observation deadline relative to nominal clip end | Full-corpus pooled WER |
| --- | ---: |
| 0 ms | 6.94% |
| +250 ms | 5.04% |
| +500 ms | 4.21% |
| +1,000 ms | 3.32% |
| +3,000 ms | 3.20% |

These are caption-availability measurements. Clip end is not an annotated speech
endpoint, and the provider adapter exposes no final-caption event. They do not
measure assistant response latency or establish an appropriate policy wait time.

## Interruptions and retained evidence

| Run | Attempted | Completed normally | Failed attempts |
| --- | ---: | ---: | ---: |
| Pilot | 20 | 20 | 0 |
| Initial full run | 376 | 368 | 8 |
| Separate startup diagnostic | 1 | 0 | 1 |
| First continuation | 328 | 327 | 1 |
| Second continuation | 305 | 305 | 0 |

The eight initial startup failures were followed by a one-session diagnostic
returning `organization_spend_limit_exceeded`. After the organization limit was
raised, those eight clips succeeded. The diagnostic is separate from corpus results.

The first continuation stopped after one unexpected session close for
`f7423ab1-0d58-5d49-5878-a433192f4759`. That clip succeeded in the second continuation.
The original runner did not retain the close payload or partial captions, so the
underlying cause remains unresolved. Subsequent runner versions retain that evidence.

The corpus therefore required **1,009 attempts for 1,000 distinct clips**, excluding
the pilot and diagnostic. Nine failed attempts remain intact. The final report is
explicitly recovered coverage, rather than an uninterrupted first-pass result.
The 695 reused successful result files passed checksum verification. All run-end
checks observed zero active session supervisors, including aborted runs.

Runner changes during recovery added configuration-checked continuation, diagnostic
retention, and source/manifest snapshots. The listening instructions, 20 ms input
pacing, three-second observation tail, provider model selection and audio derivatives
were unchanged. Each run's source and manifest hashes are in the aggregate evidence.

## Cases to investigate using this dataset

Follow-up: [the diagnostic investigation](DIAGNOSIS.md) isolates the number error
to provider caption output and equivalent-number scoring differences. The missing
caption did not recur in 14 retries; its original cause remains unresolved. These
diagnostics do not replace any baseline result below.

1. **Missing caption:** `1a9823e0-ef24-71eb-cb3a-fc50f6bb8f52`, a 3.03-second clip,
   produced no caption by the observation deadline. Its session closed normally;
   maximum input scheduling lateness was 2.72 ms. The derivative contains nonzero
   audio (peak −3.43 dBFS, RMS −20.62 dBFS). It was not retried to improve the score.
   Listen to the source and then compare a direct-provider diagnostic with Parlora
   before attributing the omission to recognition, transport, or reference quality.
2. **Numbers:** `3a7a85ed-a140-20ac-59f1-f3e45fe68837` has a reference/caption mismatch
   between “7-day” and “70” in both pilot and full evaluation. Other differences in
   the same clip concern number formatting. Review and label entity meaning
   separately; aggregate WER cannot distinguish their practical consequences.
3. **Streaming decisions:** the gap between clip-end and later caption accuracy
   provides a baseline for further timing experiments. The corpus has no OrderDesk
   task labels, so it cannot establish whether a partial caption caused a wrong
   lookup, unnecessary clarification, or stale result announcement.

## Reproduction and scope

See [commands and methodology](README.md) and [aggregate evidence](results-summary.json).
The dataset revision is `3fe50170d520c951957b86996ef082a6ab87b394`. Source audio and
reference transcripts remain local. Normalization applies NFKC, lowercase and
punctuation tokenization while retaining apostrophes and digits; it does not
normalize equivalent numeric spellings or use a semantic judge. Reference quality
should be checked by listening before treating every mismatch as a model error.

The local per-clip evidence is in
[the recovered score](runs/continuation-2-20260922/score-recovered.json).
The original attempts remain in their separate `runs/` directories. These large
artifacts and downloaded data are ignored by Git. Recompute the combined report with:

```sh
python3 validation/pipecat/score.py \
  validation/pipecat/runs/continuation-2-20260922/manifest.json \
  validation/pipecat/runs/continuation-2-20260922 --include-preserved
```

Offline verification passed: **four scorer tests and two real-session harness
tests**, plus Elixir formatting and whitespace checks. These cover deadline
scoring, missing/failed sample accounting, continuation checksums and preservation,
audio corruption rejection, paced injection, caption capture and session cleanup.

The measured path is recorded PCM → memory channel → production Parlora audio
pipeline → GPT-Live-1 captions. Browser/Opus, telephony, physical devices, application
task correctness and audible playback were outside this evaluation. The model is
requested by alias, with no fixed provider snapshot established. The pilot is a
subset of the full corpus, not an independent test set. No production behavior,
model weights, application prompts, or databases were changed.
