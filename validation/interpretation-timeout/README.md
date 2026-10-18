# Interpretation timeout investigation — September 22, 2026

**The original cause remains unproven. No timeout/retry policy was changed.**
The eight captured inputs succeeded in two direct replay modes. The original
TypeSafe timeout did not recur in the targeted or complete browser batches.
Across these distinct cohorts, **178 real TypeSafe requests succeeded**; this is
an observation count, not a production reliability estimate.

The useful changes are finer private interpretation timings, opt-in transport
phase capture, a forced-timeout regression, and a repeatable investigation.
They improve diagnosis; they do not establish a fix for the original incident.

See [results and evidence hashes](results.json), the new [release report](release-report.md),
its [JSON](release-report.json), and the [final-state review](review.json).
The prior [18/21 release baseline](../release/RESULTS.md) is retained unchanged.

## Original failure and what the code establishes

`01-cardinal-124-r1` and `14-followup-items-r3` each recorded four interpretation
judgments returning `{:error, :timeout}`, with no backend lookup. Caller captions
correctly contained the requested order. Their private records did not retain
connection/upload/response phase observations, so their precise cause cannot be
reconstructed from those records alone.

OrderDesk configures `typesafe_ai` 0.1.0 with a **2,000 ms overall deadline**, a
1,000 ms connection timeout, one attempt, four maximum concurrent streams and
an eight-entry queue. Parlora's outer policy deadline is 5,000 ms. The SDK's
overall deadline includes queueing, connection establishment, upload and response
collection. OrderDesk also waits 200 ms before classification to allow newer
transcript fragments to arrive. That explains the approximately 2,202 ms wrapper
durations; it does not identify which network/client stage consumed the deadline.
See the pinned [client implementation](https://github.com/hfiguera/typesafe_ai/blob/v0.1.0/lib/typesafe/client.ex).

The current measurements do not support raising that deadline or changing
concurrency/retry settings. The dependency and model versions remain unchanged.
The [public service-status page](https://status.typesafe.ai/) listed an earlier
resolved incident, but did not establish a cause for our later September 23 UTC
failures. It is not evidence that these requests failed upstream.

## Experiments

| Experiment | Outcome | Measured TypeSafe/client duration |
| --- | --- | --- |
| Eight original inputs, reusable connection | 8/8 API successes; all selected status for 124 | 158–514 ms |
| Same eight inputs, connection reopened before each | 8/8 API successes; all selected status for 124 | 219–445 ms |
| Two relevant browser scenarios × three attempts | 5/6 task passes; 22/22 API successes | p50 189, p95 261, max 263 ms |
| Unchanged seven-scenario release inventory × three attempts | **20/21 task passes; 140/140 API successes** | p50 186, p95 238, max 366 ms |

The direct replays use the original synthetic input snapshots in [fixtures.json](fixtures.json)
and the application's unchanged question-generation function. They test those
inputs under current service conditions, not the original transport state.

The targeted run's last follow-up case closed with provider `output_stale`; its
TypeSafe judgment succeeded. A fresh consumer build overlapped that final case,
so it is not a clean load benchmark and does not isolate the audio failure's cause.
The failure is retained and not counted as an interpretation timeout.

The complete release batch ran sequentially after that build finished, with the
same 21 cases and unchanged outcome assertions. Its sole failure was
`14-followup-items-r2`: **no captions, no delegation, no interpretation call and
no backend job**. The generic accepted-result wait expired. This is a separate
voice-session failure; there is no TypeSafe request to blame. Provider transport
capture was not enabled in that run, so its cause is also unproven.

All three save-boundary and all three reconnect repetitions passed. Final cleanup
reported zero active sessions. Independent review of all 21 database snapshots
found only the three intended browser-confirmed updates to 124, each increasing
its version once; all other cases left saved orders unchanged.

The full phase trace had 140 successful stop events, no sampled-state errors,
a maximum sampling gap of 84 ms and at most one queued request observed. Initial
connection waiting is included in that queue observation. These measurements do
not rule out a historical queue or scheduling problem. Phase sampling is not a
packet trace or proof of remote receipt.

The increase from 18/21 to 20/21 is **not attributed to a runtime fix**. The comparison
tool correctly refuses a formal equivalent-run comparison because the diagnostic
harness/settings changed. Neither cohort is a production success-rate estimate.

## Changes and validation

- Private interpretation evidence now separates `coalesce`, `evaluation`, and
  `total` milliseconds. These preserve the existing decision/error and are not
  added to the public dashboard statistics.
- `--interpretation-diagnostics` on the pilot or release command enables a
  test-only sampler for the pinned TypeSafe client. It records queue size,
  connection identity/protocol, pending upload size, response status/byte count,
  remaining deadline, mailbox size, sampling gaps and request stop outcomes.
- Sampling is bounded to about 40,000 sample/event records before periodic sampling
  stops, with a hard 44,000-record write cap. Files are mode 0600 inside the private
  run directory. Raw client state, headers, keys, request bodies and response bodies
  are never persisted by this sampler. It is not loaded by normal app startup.
- A local HTTP service that deliberately never responds verifies a real client
  deadline and phase capture, including credential/request-content exclusion.
  The first version exposed an HTTP/1 diagnostic bug: querying its body window
  after EOF raises. The sampler now queries that window only while an upload
  remains and safely records inspection failures. This fixes the diagnostic tool,
  not the original TypeSafe failure. The test now passes and runs in the offline
  release command, therefore in the existing CI matrix.
- **150 consumer tests passed**, including the new timing regression; production
  release smoke passed. **17 Node checks, six deterministic acceptance scenarios,
  two browser recovery scenarios and the forced-timeout diagnostic test passed**
  in the final offline release command. Hosted CI/Linux execution is unverified.

The paid full run used the snapshotted sampler before the HTTP/1 diagnostic guard
and teardown improvement; its observed protocol was HTTP/2 throughout and no
sampling error occurred. The current sampler was verified with the local HTTP/1
fault test. The later addition of that test to the offline command was separately
verified without repeating paid attempts. The saved reports identify their actual
source hashes; they are not relabeled as runs of later harness revisions.

## Reproduce

Build a fresh consumer or let the release command create a missing destination.
The live commands make paid requests with synthetic speech/data:

```sh
BROWSER_CHANNEL=chromium scripts/release_check.sh /absolute/consumer \
  --output /absolute/new-diagnostic-report --live --interpretation-diagnostics

python3 validation/interpretation-timeout/analyze.py \
  /absolute/new-diagnostic-report/live --output /absolute/new-phase-summary.json
```

For the smaller browser investigation, use the pilot's `--cases` and
`--repetitions` options with `--interpretation-diagnostics`. Preserve failures.
For direct service replays, run inside a consumer with its existing Keychain helper:

```sh
ORDER_DESK_TYPESAFE=1 python3 scripts/with_keychain.py mix run \
  /absolute/parlora/validation/interpretation-timeout/probe.exs \
  /absolute/parlora/validation/interpretation-timeout/fixtures.json \
  /absolute/new-probe.json 2000 auto
# Add "cold" after "auto" to close the idle connection before each request.
```

The probe reads only the small trusted fixture; its JSON-to-atom conversion is not
an input API for untrusted documents. Choose a new result path. Raw audio, complete
voice transcripts, databases, detailed samples and logs remain in ignored `runs/`.
A standalone offline sampler check is also available inside a consumer:

```sh
OPENAI_API_KEY='' TYPESAFE_API_KEY='' ORDER_DESK_DATABASE=/absolute/new-fixture.sqlite3 \
  mix run /absolute/parlora/validation/interpretation-timeout/diagnostics_test.exs
```

The original timeout cannot be called fixed on this evidence. A recurrence captured
with these diagnostics can distinguish a queued/connecting request, incomplete
upload, absent response, and delayed local scheduling before choosing a remedy.
