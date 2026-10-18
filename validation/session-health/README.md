# Session health and bounded progress recovery

This change addresses a proven recovery gap, not a proven upstream cause: a
provider can acknowledge commands and accept input while generating no captions
or delegation. Previously the acknowledgment deadline could no longer help.

## Library and host behavior

- `Parlora.status/1` includes bounded health observations: successful pipeline
  input/output writes, provider-event and caption/delegation/playback counts,
  and VM-local timestamps. No raw audio, caption text or backend inputs are added.
  Writes count silence and adapter admission, not remote receipt or audibility.
- `expect_progress/4` explicitly arms one host-chosen deadline. Matching observed
  activity or explicit host completion resolves it; acknowledgment does not.
  The default expiry action notifies. `on_timeout: :close` emits an explicit
  failure and starts existing bounded cleanup. The library never reconnects or
  replays a backend action automatically. There is no implicit silence detector.
- Cancellation, duplicate IDs, conflicting IDs, capacity exhaustion, late events,
  stale timers and normal closure have explicit behavior. Event observations
  cannot satisfy a deadline after local processing resumes beyond its expiry.
- Health is included in final session closure and progress-timeout failure events
  so hosts can retain useful evidence after the process stops. Audio counters use
  fixed atomics shared with the pipelines; there are no per-frame coordinator messages.
- OrderDesk arms a 30-second opening expectation. Any nonblank caller/assistant
  caption or delegation satisfies it, permitting an interrupted opening. It does
  not impose an end-of-turn detector or monitor every subsequent customer request.
  Browser failure controls expose manual reconnect and preserve saved state.

See the [public contract](../../docs/public-interfaces.md#15-session-health-and-opt-in-progress-deadlines)
and the `Parlora.SessionHealth` type/module documentation.

## Validation scope

The deterministic browser fixture uses the real OpenAI adapter callbacks with a
local WebSocket protocol peer and real browser media. It first withholds all
acknowledgments, then acknowledges commands while remaining silent, and finally
permits a fresh session to complete one scripted lookup. It checks visible failure,
reconnect controls, unchanged saved orders, no work replay and zero active sessions
at the end. Captions and interpretation in this fixture are scripted.

The earlier acknowledgment fixture remains part of the release command. Its
inventory now has three cases. An initial qualification run passed all individual
steps but correctly failed the wrapper's old two-case inventory assertion; that
assertion was updated to require three. The original report is retained in ignored
`runs/offline/`; it is not relabeled as a pass.

The core strict checks also exposed two existing complexity warnings in provider
option validation and diagnostic event counting. Small helper extractions preserve
those behaviors while allowing the full strict check to pass.

Exact results, source hashes and diagnostic findings are recorded in `results.json`.
Private audio, transcripts, databases and transport captures remain under ignored
`runs/`; only compact summaries are committed.

## Results

- Full `mix ci` passed: **247 tests and six properties**, three tagged checks
  excluded; native checks, strict Credo, zero clone budget, Credence and Dialyzer
  passed. **150 consumer tests** and the production release smoke passed.
- The final offline release command passed **17 Node checks, six deterministic
  acceptance scenarios, all three browser recovery cases and the forced
  interpretation-timeout test**. Recovery cleanup left zero sessions.
- The targeted live pilot passed **6/6**: cardinal 124 and status-to-items follow-up,
  each repeated three times. All opening expectations resolved on conversation
  activity. The six final database snapshots matched their starting saved orders;
  each had exactly its expected one or two reads. Cleanup left zero sessions.
- All **47 TypeSafe requests succeeded** (p50 191 ms, p95 314 ms, max 367 ms).
  No phase sampling errors/timeouts occurred. Greeting acknowledgments took
  1.14–1.34 seconds. All six provider captures contained nonzero input, no PCM
  truncation, and matching captured/transmitted-input hashes.
- Two provider traces reached the detailed-event limit (323 and 991 omitted
  records); bounded aggregate received-event counts remained available. Browser
  input statistics, provider capture and interpretation capture were enabled
  together. These are observations, not proof of remote receipt or audibility.

**The earlier silent-session failure did not recur, so its cause remains
unproven.** The local acknowledged-but-silent fixture proves the new recovery
behavior. This pilot is not a replacement 21-attempt release baseline or a
production reliability estimate. All checks ran locally on macOS; hosted CI/Linux
was not rerun. See [results and evidence hashes](results.json).

## Reproduce

```sh
scripts/consumer.sh /absolute/new/consumer
BROWSER_CHANNEL=chromium scripts/release_check.sh /absolute/new/consumer \
  --output /absolute/new/offline-report

# Paid synthetic-speech diagnostic pilot; no human voice coverage is claimed.
BROWSER_CHANNEL=chromium node validation/task-pilot/run.cjs \
  /absolute/new/consumer /absolute/new/live-report --live \
  --diagnostics --interpretation-diagnostics --repetitions 3 \
  --cases 01-cardinal-124,14-followup-items
```

The 30-second opening budget is application policy, not a service SLA. A caption
proves activity, not that a correct answer was spoken or heard. Explicit host
completion is needed when matching a particular request matters. A successful
live replay cannot establish the cause or permanent repair of an earlier outage.
