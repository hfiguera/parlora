# Observe a Parlora session

Parlora exposes runtime measurements through `:telemetry` and conversation events
through `Parlora.subscribe/2`. The host application installs handlers, chooses
metric aggregation and trace sampling, and configures exporters and Logger.
Parlora starts no reporter, monitoring server, exporter or Docker service.

These observations describe runtime behavior. Your application defines business
success, answer correctness and user satisfaction.

## Operation events

`Parlora.Telemetry.events/0` returns the operation events and the operational event
stream below. Each operation emits `[:parlora, operation, :start]` and
`[:parlora, operation, :stop]`.

| Operation | Start | Stop |
| --- | --- | --- |
| `:session` | Coordinator initialization | Coordinator closure or observed termination |
| `:startup` | Coordinator initialization | Readiness, startup failure, deadline or early closure |
| `:shutdown` | First close transition | Coordinator cleanup settles, or the shutdown deadline expires |
| `:policy` | Context policy callback scheduled | Callback returns, crashes, times out or is cancelled |
| `:backend_queue` | Request revision created | Backend start observed, or tracking ends before start |
| `:backend` | First matching backend `:request_started` | Matching terminal result, uncertainty or closure |
| `:delivery` | Verified backend result recorded | First accepted, rejected, unconfirmed, unknown, stale or inapplicable delivery outcome, or closure |
| `:interruption` | Provider interruption handled | Clear/resume command completes or its admission fails |
| `:recovery` | Output recovery admitted | Matching reconnection observed or session closes |

Start measurements contain `system_time` and `monotonic_time`. Stop measurements
add `duration` and `count: 1`. **All three time measurements use native time units**:
convert durations with `System.convert_time_unit(duration, :native, :microsecond)`.
Only subtract monotonic timestamps from the same VM. `system_time` is for external
correlation, not duration calculation.

Metadata includes an opaque `operation_id` and `session_id`. Child operations
include `parent_operation_id` pointing to the session operation. Request operations
also carry `request_id`, `task_id`, `task_revision`, `provider_generation` and,
when present, `delegation_id`. Session metadata identifies channel, provider and
backend modules. Stop metadata includes `outcome`; unknown categories become
`:other`. IDs correlate observations; they are not OpenTelemetry trace IDs.

Important boundaries:

- Startup begins in the coordinator, after public argument validation. Returning
  `{:ok, pid}` does not end startup.
- Queue wait includes coordinator/admission delay and backend start notification
  delay. Backend duration begins only when start is observed. A result without a
  start notification does not invent an execution duration. For queue latency
  distributions, select only queue stops with `outcome: :started`; other outcomes
  measure tracking that ended without a start observation.
- An updated request can retain its execution identity. A replacement request has
  its own observations. Revisions remain explicit; speech interruption does not
  imply cancellation of external work.
- `:uncertain` ends our measured observation interval, not necessarily external
  execution. A later verified result can still be delivered.
- Delivery measures completion to the **first** delivery outcome. An unconfirmed
  submission may later be acknowledged; that produces an operational event, not
  a second duration for the same delivery operation.
- Successful recovery means reconnection was observed. It does not establish
  that the caller has resumed speaking or that a result was heard.
- Interruption duration includes command queueing, channel clear and provider resume
  acknowledgment. It starts after provider detection; it does not measure physical
  user speech onset or the last sound heard on the device.
- Shutdown measures coordinator cleanup/deadline. A timeout is not proof every
  external resource has been released. A VM crash or untrappable process kill
  cannot emit its own final observation; host monitoring must detect that.

## Operational events

`[:parlora, :runtime, :event]` emits `count: 1` for an allowlist of failures,
rejections, cancellation observations, uncertain requests, stale results, delivery
stages, recovery, interruptions, playback, discontinuities and provider usage.
Metadata includes `source` and `type`, correlation IDs where known, and allowlisted
`stage`, `cause`, `boundary`, `evidence`, `role` and `recovery_release_reason` where supplied. It never copies raw
payloads, error messages/details, prompts, options, transcripts or tool data.
Unknown category values become `:other`.

Available numeric measurements include `duration_us`, `inserted_silence_us`,
`source_unavailable_us`, `recovery_wait_us`, `dropped_bytes`, `dropped_frames`,
`dropped_duration_us` and provider-reported `seconds`. Fields are absent when
unavailable. `*_us` fields use microseconds, unlike operation `duration`.

Operational events are adapter observations, not exactly-once business outcomes.
Duplicate or late adapter events can be observed even if the coordinator rejects
them. Use operation stops for duration counts. Expected cancellation and stale
result rejection are not automatically errors. Usage updates may be cumulative:
do not add interim updates to final usage, and never replace unavailable usage
with zero.

The existing `[:parlora, :event]` counter remains unchanged, with only `source` and
`type` metadata. Conversation events remain available through `subscribe/2`;
**they can contain application data and are not safe to forward wholesale**.

## Audio measurements

Existing audio instrumentation remains available independently of the low-volume
operation stream. `Parlora.Telemetry.events/0` deliberately does not attach handlers
to these high-frequency events. Useful measurements include:

| Event | Measurements and units |
| --- | --- |
| `[:parlora, :provider, :audio_received]` | `bytes`, `duration_us`, `queue_before_bytes`, `queue_bytes`, `queue_duration_us`, `oldest_age_us`, `dropped_bytes`; `outcome` metadata |
| `[:parlora, :provider, :audio_read]` | `bytes`, `queue_bytes`, `queue_duration_us`, `oldest_age_us` after read |
| `[:parlora, :audio, :tick]` | `work_us`, `late_us`, `pending_frames`, `blocked` (0/1), `blocked_duration_us` (current episode age), `delay_ms`; `direction` metadata |
| `[:parlora, :audio, :frame]` | `bytes`, `duration_us`; input/output `direction` |
| `[:parlora, :audio, :playout]` | Browser PCM: `source_bytes`, `silence_bytes`, `padding_bytes`, `queue_bytes`, `staged_bytes`, `playback_target_ms`, `recovering` (0/1), cumulative `starvations` |
| `[:parlora, :audio, :playout_gap]` | Browser gap summary including `duration_us`, `source_unavailable_us`, `recovery_wait_us` and amplitude evidence |

Audio `at_us` values are local monotonic microseconds. Convert queue bytes to
milliseconds using the negotiated format, not a fixed divisor: PCM24 and PCMU8
have different byte rates. Treat cumulative starvation values as gauges or derive
deltas; summing every snapshot double counts.

Gap observations distinguish source unavailability from additional recovery wait.
Idle silence, intentional clears and interruptions must be excluded before
classifying candidate speech disruptions. Nonquiet audio around a gap is evidence,
not proof of lost speech. Absence of source audio does not identify whether its
cause is the provider, network or local processing.

Provider acceptance, channel handoff, estimated playback and device-reported
playback are separate evidence levels. None proves a person heard the response.
There is no universal end-of-user-turn or time-to-first-spoken-response metric:
some continuous providers do not supply reliable turn boundaries. Applications
can derive it when their integration supplies the required observations; do not
infer it from caption delta timing.

## Host integration

Attach explicitly in the host's supervision/startup code, and detach on shutdown:

```elixir
:telemetry.attach_many(
  "my-app-parlora",
  Parlora.Telemetry.events(),
  &MyApp.ParloraObserver.handle_event/4,
  observer_pid
)
```

A handler executes synchronously in the emitting process. Keep it short: updating
a metric or submitting to a bounded host-owned buffer is appropriate; HTTP export,
JSON encoding, disk writes and blocking calls are not. A handler exception causes
Telemetry to detach it. Detect handler/export failures in the host's monitoring.

Use bounded metric labels such as operation, outcome, channel and provider. Keep
session/task IDs for trace and log correlation. The host chooses histogram buckets,
percentiles, alert thresholds and model/configuration labels. VM metrics, business
metrics, retention, sampling and exporter credentials also belong to the host.

An optional OpenTelemetry bridge can map operation IDs to span contexts and use
parent IDs to preserve overlapping work across processes. Do not rely on implicit
process context inheritance. Use real operation timestamps, and translate them
using the tracing API's clock convention. Do not create spans per audio packet or
caption delta. A continuous voice connection is not a sequence of invented model
generation calls. Observed discrete backend LLM calls may have generation spans.

## Logs and detailed capture

Parlora does not change Logger levels, handlers or formatting. Use ordinary Elixir
levels: `:debug` for internal diagnostics, `:warning` for unexpected conditions
requiring attention, and `:error` for unrecovered failures. A returned error need
not be logged at every layer. Host code can log session summaries from events.

Do not turn every frame into a debug log. Detailed recording/capture should be
explicitly enabled and bounded in the host, with retention and access controls.
Opaque identifiers can themselves be application data: use non-sensitive IDs and
redact further before external export as appropriate.

## Optional local development stack

The checkout includes `examples/observability`, a separate development host with
VictoriaMetrics, VictoriaTraces and an OpenTelemetry Collector. Its reporter and
tracing dependencies are **not dependencies of Parlora**. The offline demo needs
no voice API keys and uses no business success metrics or recorded audio.

See [the development setup](https://github.com/hfiguera/parlora/tree/main/examples/observability)
for startup, queries, tests and shutdown commands. The library's tests run without
Docker or an observability SDK.
