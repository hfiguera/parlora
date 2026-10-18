# Acceptance and separate audio assessment — 2026-09-21

Subsequent implementation changes and retests: [fix report](fix/README.md).

Code under test: Parlora commit `1f1d1fb` (`Preserve clarification context
across streamed requests`), with the matching standalone consumer and vendored
library. No production code or acceptance assertions were changed for this run.
Elixir `1.20.4-otp-29`, Erlang `29.0.6`; macOS Rust toolchain
`1.92.0-aarch64-apple-darwin`. This is validation evidence, not a release certificate.

## Conversation results

| Suite | Result | Coverage / limitation |
| --- | --- | --- |
| macOS deterministic acceptance | 6/6 passed | Corrections, clarification, status/items, draft/refusal, corrected draft confirmation, interruption/disconnect/cleanup |
| Linux deterministic acceptance | 6/6 passed | Same six cases on the pinned toolchain |
| Live browser | 5/6 passed | Draft/refusal stopped before a draft was created; other five cases passed |
| Live Twilio | 3 passed, 1 failed, 2 not run | Refusal left interpretation unresolved; existing harness stops at first failure |
| Live Telnyx | 2 passed, 1 failed, 3 not run | Items follow-up did not start an items job; existing harness stops at first failure |

These are single runs, with failures retained and no retry used to replace them.
The live cases use synthesized caller audio and real provider/model connections.
Deterministic local audio uses a synthetic device; these results do not represent
six physical microphone conversations. Browser confirmation and reconnection
passed; the later phone cases remain untested in this run.

### Browser: draft was never created

The transcript split the request into “For order one hundred twenty” and
“four, change the delivery instructions to leave it at reception,” with an
assistant response between them. No backend job or pending draft appeared.
The assistant ultimately requested the number again. The test timed out waiting
for the draft, so it never reached spoken refusal or the Reject button.

See [browser report](browser-report.json),
[failure evidence](browser-draft-failure.json), and the subsequent
[root-cause investigation](root-causes/README.md).

### Twilio: accepted refusal, unresolved interpretation

The delivery draft and refusal jobs both completed, and both results were
accepted. However, the user’s refusal arrived in fragments: “No … don't save …
that Keep the original … instructions.” A clarification associated with the
trailing `instructions` fragment left interpretation `unresolved`.

The timeout label, `accepted 124 refuse`, also requires settled interpretation
and claimed delegations. It does **not** mean that the refusal job failed or its
result was never accepted. Correction to the initial assessment: the current
application deliberately rejects an identified draft on spoken refusal.
The assistant's statement that it was rejected was accurate: read-only database
inspection confirmed `rejected`, with no saved instruction changes. The older
expectation that refusal leaves a pending draft no longer matches the code and
current acceptance assertions. The failure here is the unnecessary clarification,
not the rejection. See [database evidence](root-causes/twilio-database.json).

See [Twilio report](twilio-report.json) and
[failure evidence](twilio-draft-failure.json).

### Telnyx: items request transcribed, no corresponding job

The status lookup for 124 completed and its result was accepted. The next request
was transcribed as “What items are in that … order?” with the assistant saying
“Checking” between the fragments. Only the status job and its claimed delegation
were present at timeout. Interpretation was `settled`, but no items job started.

See [Telnyx report](telnyx-report.json),
[failure evidence](telnyx-items-failure.json), and the subsequent
[controlled policy/session replays](root-causes/README.md).

## Audio assessment

### Live generated speech: one starvation observation, no active-signal boundary cut

The bounded PCM save-announcement probe captured the actual generated PCM
returned by `Parlora.Playout.take/4`, before CPAL conversion. It recorded:

- 981 output blocks, 15,480 ms of source PCM and 17,550 ms of total playout PCM.
- One starvation observation and one interior insertion of 240 ms of silence.
- Immediately before that insertion: PCM peak 0, RMS 0.
- Immediately after: PCM peak 1, RMS 0.45, on the signed 16-bit scale.
- Zero insertions bounded by active signal on both sides.

The insertion occurred between the initial draft announcement and the subsequent
save update. It extended a quiet interval; the captured boundary does not show a
cut through active speech. That does **not** prove the extra pause was inaudible,
nor certify the whole call as glitch-free. The probe observed the save-update
transcript and finalized normally, with no output-overflow closure.

The earlier manual call's starvation observations cannot be classified
retrospectively: that call did not retain the corresponding output waveform.
The browser acceptance run also recorded starvation notifications; those remain
unclassified by waveform. Functional passes do not certify their audio quality.

See [numeric audio evidence](audio-summary.json). Full local artifacts:

- `/tmp/parlora-regression-20260921-audio/capture.json`: generated output only.
- `/tmp/parlora-regression-20260921-audio/trace.json`: timestamped pipeline evidence.
- `/tmp/parlora-regression-20260921-audio/playout.wav`: output including inserted silence.
- `/tmp/parlora-regression-20260921-audio/source.wav`: source blocks without inserted silence.
- `/tmp/parlora-regression-20260921-audio/live.log`: transcripts and finalization.

No microphone recording was retained. The WAVs are pre-device reconstructions,
not recordings of a speaker, browser receiver, or phone endpoint. Trace collection
adds overhead and may omit the first block. This probe ran alongside the Twilio
functional suite; it is not an isolated latency benchmark.

### Reproducible classification

[record_playout.exs](record_playout.exs) bounds capture to 6,000 blocks and wraps
the existing bounded save-announcement/PCM trace probe.
[analyze_playout.py](analyze_playout.py) distinguishes source blocks using their
cumulative source-byte count, then measures silence inserted between source
blocks. It checks up to 20 ms at each boundary, with RMS 64 as a transparent
active-signal threshold. This is a signal heuristic, not a speech/VAD classifier.
Silence after the final source block is excluded from interior-gap counts.

Three known-signal controls passed: an insertion between nonzero blocks is
flagged; an insertion between silent blocks is retained but not marked as active
speech evidence; terminal silence is excluded. Eleven existing playback
regression tests also passed; see [test log](playback-tests.log).

Reproduce the capture from `/Users/humberto/Projects/parlora_consumer` with a new
private output directory and the existing Keychain wrapper:

```sh
ORDER_DESK_DATABASE=:memory: PARLORA_SAVE_PROBE_FORMAT=pcm \
PARLORA_TRACE_OUTPUT=/tmp/parlora-audio-check/trace.json \
PARLORA_CAPTURE_OUTPUT=/tmp/parlora-audio-check/capture.json \
RUSTUP_TOOLCHAIN=1.92.0-aarch64-apple-darwin \
ERL_FLAGS='+sbwt none +sbwtdcpu none +sbwtdio none' \
python3 scripts/with_keychain.py mix run \
  /Users/humberto/Projects/parlora/validation/regression-20260921/record_playout.exs
```

Then, from the library repository:

```sh
python3 validation/regression-20260921/analyze_playout.py /tmp/parlora-audio-check/capture.json
python3 validation/regression-20260921/test_analyze_playout.py
```

### Device controls

Linux PulseAudio virtual loopback passed: recovered tone amplitude approximately
800 while playing and after resume, zero stopped-tail amplitude, no capture
drops or device errors. Clear took 5.298 ms, close 6.031 ms. See
[Linux audio evidence](linux-audio.log). Physical Linux audio remains unverified.

macOS physical speaker/microphone controls passed with no capture drops or
device errors. Tone amplitude rose from baseline 1.61 to 214.26 while playing,
fell to 2.97 after stopping, and recovered to 239.61 after resume. Clear took
4.273 ms; close took 31.157 ms. Approximate captured tail was 140 ms, which
includes device and acoustic capture delay rather than measuring the clear
command alone. See [macOS device evidence](macos-audio.log).

The macOS continuous-tone jitter probe consumed all 10,000 ms of source audio
with zero inserted gaps and zero steady-state native underrun frames. Its four
startup underrun frames remain in the record. It used the existing probe's
60 ms buffer and alternating 20 ms delivery jitter. See
[macOS jitter evidence](macos-jitter.log). These test device operation and
controlled delivery, not the subjective quality of every live spoken call.

## Cleanup and reproducibility

Both telephone harnesses restored and verified the original provider routing,
completed their own call legs, deleted their temporary caller application, and
stopped their test servers/tunnels. See [Twilio cleanup](twilio-cleanup.json) and
[Telnyx cleanup](telnyx-cleanup.json). The regular demo server and ngrok were
already stopped before testing. Credentials were supplied by the existing
Keychain wrappers and are not included in this evidence.

Commands used, with the pinned macOS environment above:

```sh
scripts/acceptance.sh /Users/humberto/Projects/parlora_consumer --live --output /tmp/parlora-regression-20260921-browser
PARLORA_ACCEPTANCE_LIVE=1 ORDER_DESK_TWILIO=1 ORDER_DESK_TYPESAFE=1 python3 examples/order_desk/scripts/with_keychain.py python3 validation/twilio/live.py /tmp/parlora-regression-20260921-twilio --suite
PARLORA_ACCEPTANCE_LIVE=1 ORDER_DESK_TELNYX=1 ORDER_DESK_TWILIO=1 ORDER_DESK_TYPESAFE=1 python3 examples/order_desk/scripts/with_keychain.py python3 validation/telnyx/live.py /tmp/parlora-regression-20260921-telnyx --suite
mix test test/playout_test.exs test/playout_starvation_regression_test.exs test/playback_pressure_test.exs test/playback_refill_test.exs
```

Linux used `/tmp/parlora-browser-linux-env.sh` and Node
`/tmp/parlora-acceptance-node/node-v22.16.0-linux-x64/bin`, then ran
`scripts/acceptance.sh /tmp/parlora-browser-package-audit --output /tmp/parlora-regression-20260921-offline`
and `scripts/linux_audio.sh` from `/tmp/parlora-v1-20260915`.
Two initial Linux launches lacked Node on PATH and did not run acceptance cases;
their infrastructure logs are preserved in `/tmp/parlora-regression-20260921-linux*.log`.
The successful results are in [Linux offline report](linux-offline-report.json).

The existing consumer compiler warning about the unreachable
`continue_pending/2` clause remains visible in live logs. These validation runs
did not change that code or suppress warnings.

## Next action supported by this evidence

Investigate the three live interpretation/delegation failures, starting with the
preserved streamed transcripts. Preserve the current acceptance assertions.
For audio, correlate future observations with captured source/playout samples
and endpoint evidence where available; neither a zero counter nor a nonzero
counter alone is a speech-quality verdict.
