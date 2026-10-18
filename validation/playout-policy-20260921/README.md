# Whole-stream playout policy comparison — September 21, 2026

**Decision: retain the production policy.** Immediate recovery improves some
individual pauses but creates later gaps in a recorded stream. The tested fixed
refill targets also trade fewer/shorter gaps in one recording for worse results
in another. No replacement is approved by this experiment.

Production `lib/` remains at `78b1192`. The changes add replay measurements,
recorded-arrival browser playback, and a permanent regression test. The example
server on port 4000 was not changed by the experimental policy substitution.

See the [source review](../../docs/audio-playout-review.md) for the pinned
Pipecat and LiveKit implementations that motivated the immediate-resumption
reference. This compares Parlora policies, not those frameworks' running systems.

## Inputs and method

- Nine synthetic 20-second schedules: steady, jitter, burst, variable chunks,
  scheduler delay, one shortage, sustained underproduction, late bursts, and
  repeated shortages. Seed 42; output-clock phases 0, 5 and 9 ms.
- Two complete earlier recorded arrival schedules:
  [short](../pcm-overflow/starvation-evidence.json) and
  [long](../pcm-overflow/refill-trial-arrivals.json). These retain timing and
  sizes, not the original speech.
- [Fresh live arrivals](arrivals.json): a bounded 35-second GPT-Live probe,
  340 packets, 1,632,000 bytes / 34 seconds of 24 kHz mono s16 PCM. No dropped
  bytes; every received byte was retained; session finalized. Three prompts
  requested a fixed fictional order sentence. Input was generated silence,
  with no microphone or caller recording.
- Fourteen configurations: frozen baseline, current production, immediate
  recovery with 60/100/120 ms initial buffers, strict 120 ms startup followed by
  immediate recovery, and eight bounded refill target/deadline combinations.
  [Policies](policies.exs) define every parameter. No queue limits were enlarged.

The virtual replay drives the existing transfer pipeline with synthetic
continuous-phase PCM having exactly the recorded byte counts. It checks byte
integrity, queue bounds, startup and existing normal-envelope gates, and reports
all internal gaps, inserted silence, completion time and maximum source-frame
age at consumption. Frame age is relative to receipt, not microphone or model
generation time. A packet's fragments retain its receipt timestamp.

`passed` in the comparison means the existing invariant/envelope checks pass.
It does **not** mean that the candidate improves recorded speech. Recorded and
adverse schedules deliberately report gaps without certifying their quality.
The virtual clock does not reproduce OS scheduling, network loss, or speakers.

## Findings

At phase 0 of the older long recording:

| Policy | Internal gaps | Total inserted silence |
| --- | --- | ---: |
| Existing 120 ms policy | 260 ms | 260 ms |
| Immediate recovery, initial 120 ms | 200, 50, 10 ms | 260 ms |

Immediate recovery shortens the largest pause by 60 ms, but spends the recovered
buffer reserve and produces two later gaps. Optimizing only the largest gap or
the recovery-wait counter would hide this regression. The new
[regression test](../../test/audio_policy_comparison_test.exs) preserves this
counterexample and requires production to stay within its gap count, silence,
startup and source-age bounds; it permits a future policy that improves them.

The original immediate-recovery implementation also failed two historical
refill tests during Linux CI. That [failed run](immediate-candidate-linux-ci.log)
is preserved. The implementation was reverted, not accommodated by relaxing
those tests.

On the fresh complete live schedule, both the baseline and immediate-120 policy
have a worst-phase total of 160 ms inserted silence and a largest gap of 70 ms.
Larger fixed refill cushions increase the worst-phase total to 220–240 ms.
Smaller initial buffers also fail the normal scheduler-delay continuity gate.
There is no demonstrated overall improvement from copying another framework's
immediate-consumption behavior or choosing another refill constant.

The final [504-case comparison](comparison.json) preserves every result:
489 pass the existing checks and 15 fail. Six failures are scheduler-continuity
cases with 60/100 ms initial buffers; nine are repeated-shortage recovery-delay
cases with larger refill settings. Current production and the frozen baseline
pass all 36 of their cases and have identical playout timing and gap results
(observed process mailbox peaks can vary). Passing these checks alone
does not resolve the remaining speech gaps described above.

## Real browser speech comparison

The first 250 packets / 25 seconds of the fresh generated speech were replayed
with their recorded timing through the real Browser channel, libopus, RTP, and
Chromium decoder. Both runs used isolated VMs on port 4002, sequentially and
without concurrent benchmark/CI work on that host.

| Observation | Current policy | Immediate recovery |
| --- | ---: | ---: |
| Source bytes handed to playback | 1,200,000 | 1,200,000 |
| Completed internal gap observations | 4 | 5 |
| Inserted PCM in those gaps | 140 ms | 140 ms |
| Longest observed gap | 69.734 ms | 69.898 ms |
| Receiver packet loss / concealed samples | 0 / 0 | 0 / 0 |
| Track-capture discontinuities | 0 | 0 |
| Resource cleanup | Pass | Pass |

[Diagnostics, capture hashes and local paths](speech/summary.json) preserve both
runs. Full browser observations: [current](speech/current.json),
[immediate](speech/immediate.json). Final queue-empty time after the finite source
ends is excluded from the internal-gap totals. Natural silence in source PCM is
not counted as inserted silence. Real-clock phase and scheduling vary between
runs, so this single A/B pair is illustrative, not a statistical ranking.

The speech was captured after decoding, before physical speakers. **No human
listening verdict is claimed.** Boundary amplitudes are not a speech detector;
even the extra immediate-recovery gap has low-amplitude boundaries. The chirp
analyzer is intentionally not used to classify natural speech silence. Raw
generated speech stays in `/tmp`; only numeric diagnostics are checked in.

## Validation

Both pinned-toolchain `mix ci` runs pass: **233 tests/properties, 3 excluded**,
plus native tests, Credo/ex_slop, ex_dna, Credence and Dialyzer.
[macOS log](checks/macos-ci.log), [Linux log](checks/linux-ci.log).
The unchanged production playback path is also exercised by the existing
200-schedule PCM matrix, nine analyzer controls and seven decoded-browser
scenarios per platform. See [macOS](checks/macos-audio/report.json) and
[Linux](checks/linux-audio/report.json). Linux is a mirrored checkout; its report
has no Git revision, but records source hashes for comparison.
The two reports have identical library and benchmark-harness hashes.

These checks do not establish production readiness. Physical Linux playback,
telephony receiver quality, controlled network impairment, sustained load and
capacity qualification remain separate evidence requirements.

## Reproduce

From the repository root, with the pinned Elixir/Erlang/Rust toolchain:

```sh
export ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none'
export MIX_ENV=test
mix test test/audio_policy_comparison_test.exs
PARLORA_ARRIVAL_SCHEDULE=validation/playout-policy-20260921/arrivals.json \
  PARLORA_POLICY_REPORT=/tmp/playout-comparison.json \
  mix run validation/playout-policy-20260921/compare.exs
scripts/audio_benchmark.sh /tmp/playout-gates
```

The comparison has 504 cases when all three recorded schedules are included.
Set `PARLORA_POLICY_SCOPE=recorded` for only the 126 recorded cases. The baseline
source is frozen in [recorded_playout.exs](recorded_playout.exs); it does not depend
on the current Git checkout resolving an old commit.

To obtain a new bounded live capture (uses the existing development credential
and incurs API usage):

```sh
PARLORA_CAPTURE_OUTPUT=/tmp/playout-arrivals.json \
  python3 scripts/with_keychain.py mix run \
  validation/playout-policy-20260921/capture.exs
```

For the speech A/B, prepare a matching prefix of at most 25 seconds of the
resulting PCM and arrivals (the server checks exact byte accounting). For this
run that was 250 packets, each 100 ms / 4,800 bytes:

```sh
python3 - <<'PY'
import json
from pathlib import Path
capture = json.loads(Path('/tmp/playout-arrivals.json').read_text())
prefix, total = [], 0
for row in capture['arrivals']:
    if total + row['bytes'] > 25 * 48_000:
        break
    prefix.append(row)
    total += row['bytes']
Path('/tmp/parlora-policy-speech.json').write_text(json.dumps({'arrivals': prefix}))
Path('/tmp/parlora-policy-speech.pcm').write_bytes(
    Path('/tmp/playout-arrivals.json.pcm').read_bytes()[:total])
PY
```

Then set the absolute file paths:

```sh
AUDIO_REFERENCE_PCM=/tmp/parlora-policy-speech.pcm \
  AUDIO_ARRIVAL_SCHEDULE=/tmp/parlora-policy-speech.json \
  sh validation/playout-policy-20260921/speech.sh /tmp/playout-speech
```

Requires the existing locked Playwright installation under `validation/browser`.
Do not run CPU-heavy comparisons or CI on the same host during browser timing
measurements. Experimental policy replacement is confined to the benchmark VM.

## Next policy experiment

Evaluate a bounded delay controller based on cumulative source duration versus
arrival time, with explicit latency and continuity budgets. Test it on these
whole streams and unseen captures, not just selected gap windows. A higher target
cannot create missing samples: increasing delay during playback requires a
pause or an independently evaluated rate-adjustment method. Preserve source
samples, clear/epoch semantics and finite queue bounds. Before adoption, compare
decoded speech with its source and obtain a listening verdict; a lower counter
alone is not sufficient.
