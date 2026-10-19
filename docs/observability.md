# Metrics, traces and logs

Parlora exposes runtime measurements through `:telemetry` and conversation events
through `Parlora.subscribe/2`. The host application installs handlers, chooses
metric aggregation and trace sampling, and configures exporters and Logger.
You can use your existing monitoring stack; Parlora requires no monitoring service.

These observations describe runtime behavior. Your application defines business
success, answer correctness and user satisfaction.

## Connect your monitoring

Attach handlers once when your application starts, before starting sessions. This
minimal example logs one summary per closed session using only operational fields:

```elixir
defmodule MyApp.ParloraObserver do
  require Logger

  def attach do
    :telemetry.attach(
      "my-app-parlora-session",
      [:parlora, :session, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def detach, do: :telemetry.detach("my-app-parlora-session")

  def handle_event(_event, %{duration: duration}, %{outcome: outcome}, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :microsecond) / 1_000
    Logger.info("Parlora session stopped: outcome=#{outcome} duration_ms=#{duration_ms}")
  end
end
```

Call `MyApp.ParloraObserver.attach()` from your application's startup code and
`MyApp.ParloraObserver.detach()` when removing the integration. The handler observes
all sessions in that VM. It does not require a subscription to each session.
Replace the callback with your metric reporter or tracing integration as needed.
To receive all operation and operational events, use `:telemetry.attach_many/4`
with `Parlora.Telemetry.events/0`; audio events are selected separately.

Handlers run synchronously in the emitting process. Keep them short: update a
metric or submit to a bounded buffer. Export HTTP requests, encode JSON and write
files outside the callback. A handler exception causes Telemetry to detach it;
monitor handler and exporter failures in your application.

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

### Timing boundaries

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

## Operational observations

`[:parlora, :runtime, :event]` emits `count: 1` for an allowlist of failures,
rejections, cancellation observations, uncertain requests, stale results, delivery
stages, recovery, interruptions, playback, discontinuities and provider usage.
Metadata includes `source` and `type`, correlation IDs where known, and allowlisted
`stage`, `cause`, `boundary`, `evidence`, `role` and `recovery_release_reason`
where supplied. It never copies raw payloads, error messages/details, prompts,
options, transcripts or tool data.
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

The older `[:parlora, :event]` counter includes only `source` and `type` metadata.
Use either this counter or the operational stream for a given event count, so you
do not count the same observation twice.

Conversation events received through `Parlora.subscribe/2` are a separate API.
They can contain application data, including transcripts and backend results;
select and redact fields before exporting them.

## Audio measurements

Audio measurements are emitted more frequently than operation events. Select
only the events you need; `Parlora.Telemetry.events/0` lists event names and does
not include the audio stream. The built-in providers share these receipt and read
measurements:

| Event | Measurements and units |
| --- | --- |
| `[:parlora, :provider, :audio_received]` | `bytes`, `duration_us`, `queue_before_bytes`, `queue_bytes`, `queue_duration_us`, `oldest_age_us`, `dropped_bytes`; `outcome` metadata |
| `[:parlora, :provider, :audio_read]` | `bytes`, `queue_bytes`, `queue_duration_us`, `oldest_age_us` after read |
| `[:parlora, :audio, :tick]` | `work_us`, `late_us`, `pending_frames`, `blocked` (0/1), `blocked_duration_us` (current episode age), `delay_ms`; `direction` metadata |
| `[:parlora, :audio, :frame]` | `bytes`, `duration_us`; input/output `direction` |
| `[:parlora, :audio, :playout]` | Browser PCM: `source_bytes`, `silence_bytes`, `padding_bytes`, `queue_bytes`, `staged_bytes`, `playback_target_ms`, `recovering` (0/1), cumulative `starvations` |
| `[:parlora, :audio, :playout_gap]` | Browser gap summary including `duration_us`, `source_unavailable_us`, `recovery_wait_us` and amplitude evidence |

Provider receipt is measured once per decoded packet, before splitting it into
pipeline frames. Receipt `bytes` is the incoming packet size, including rejected
packets; `outcome` is `:accepted` or a rejection code. `dropped_bytes` counts
rejected incoming bytes, while later removal of queued audio is a separate
discontinuity. Sum accepted packet durations to measure received source audio;
quiet samples count too.

Read `bytes` is the size removed from the queue. Queue size, duration and oldest
audio age describe what remains after the read; `oldest_age_us` is zero when
empty. Both provider events carry `session_id`, `adapter_id` and `generation`
metadata and contain no PCM or text. Receipt is a local observation, not a
timestamp from the remote generator.

Audio `at_us` values are local monotonic microseconds. Convert queue bytes to
milliseconds using the negotiated format, not a fixed divisor: PCM24 and PCMU8
have different byte rates. `queue_duration_us` already accounts for that format.
Treat cumulative starvation values as per-session gauges or derive deltas before
aggregating; summing every snapshot double counts.

Gap observations distinguish source unavailability from additional recovery wait.
Idle silence, intentional clears and interruptions must be excluded before
classifying candidate speech disruptions. Nonquiet audio around a gap is evidence,
not proof of lost speech. Absence of source audio does not identify whether its
cause is the provider, network or local processing.

Provider acceptance, channel handoff, estimated playback and device-reported
playback are separate evidence levels. None proves a person heard the response.
There is no universal metric for the end of a user turn or time to the first
spoken response: some continuous providers do not supply reliable turn boundaries. Applications
can derive it when their integration supplies the required observations; do not
infer it from caption delta timing.

## Build metrics and traces

Your reporter chooses metric names, units and histogram buckets. For example,
convert operation durations from native units to seconds and name the exported
histogram with a `_seconds` suffix. Convert to milliseconds only when displaying
that value. Raw audio fields ending in `_us` are microseconds, not native units.

Group metrics by bounded categories such as operation, outcome or audio direction.
Provider and channel module names are available on session and request operations;
other observations may not carry them. Optional labels such as `stage` need a
consistent default in your reporter when absent. Keep session, task, request and
operation IDs for correlation in traces or logs, rather than metric labels.

Queue and playback observations from concurrent sessions should not overwrite one
global gauge. Use distributions weighted by observations, or aggregate active
sessions explicitly in your host. A histogram percentile is an
estimate based on its buckets; it is not an exact latency measurement for a call.

For tracing, map `operation_id` to a span context and `parent_operation_id` to its
parent. Carry that mapping across processes; implicit process context does not
follow Parlora's asynchronous work. Associate the session root with any existing
host request trace explicitly, and translate timestamps using your tracing SDK's
clock convention. End spans using the recorded stop time, rather than export time.

Create spans for session operations and observed backend calls, rather than for
each audio packet or caption delta. A continuous voice connection does not imply
a series of discrete model generation calls. Sampling, retention, credentials and
exporter queues are configured by your application.

## Logs and detailed capture

Parlora reports runtime observations through events; it does not log each one or
configure your application's Logger handlers, global level or formatting. Your
application decides which observations to log. Use standard Elixir levels:

- `:debug` for diagnostics while investigating a problem.
- `:info` for lifecycle summaries your application chooses to log, as above.
- `:warning` for unexpected conditions that need attention.
- `:error` for unrecovered failures.

Expected cancellation and stale result rejection need not produce warnings.
Avoid logging the same returned error at every layer.

Do not turn every frame into a debug log. Detailed recording/capture should be
explicitly enabled and bounded in the host, with retention and access controls.
Opaque identifiers can themselves be application data: use non-sensitive IDs and
redact further before external export as appropriate.

## Example integration

The repository includes a [separate development host](https://github.com/hfiguera/parlora/tree/main/examples/observability)
with a metric reporter, an OpenTelemetry bridge and a local Collector setup.
Its README contains local setup instructions. Those dependencies and
services are optional and are not installed by Parlora.
