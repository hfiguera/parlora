# Observability development host

This optional example connects Parlora to VictoriaMetrics and VictoriaTraces
through an OpenTelemetry Collector. It is a separate Mix application: its
reporter, tracing SDK, HTTP listener and Docker services are not dependencies of
Parlora. See [Metrics, traces and logs](../../docs/observability.md) for the public
event contract and integration guidance.

The demo runs a real Parlora session using deterministic test adapters from this
checkout. It needs no API keys and records no audio. Use it to explore the
integration and check exported observations, rather than to assess voice quality
or live provider performance.

## Run

From the repository root:

```sh
cd examples/observability
docker compose up -d
mix deps.get
mix run demo.exs
```

The initial build needs the [runtime and native prerequisites](../../docs/beam-compatibility.md).
Device and Opus bindings are disabled for this example, and no Jido, Sagents or
Legion dependency is installed.

Keep the command running after it prints the session ID. The host serves metrics
and exports traces asynchronously while you inspect them:

- Metrics source: http://localhost:19100/metrics
- VictoriaMetrics UI: http://localhost:18428/vmui/
- VictoriaTraces UI: http://localhost:19428/select/vmui/
- Collector health: http://localhost:13133/

## Inspect metrics and traces

Paste these MetricsQL queries into VictoriaMetrics. They show backend outcomes,
mean backend duration in milliseconds, mean queued audio duration in milliseconds,
and operational observations:

```promql
sum by (outcome) (parlora_backend_stop_count_total)
1000 * sum by (outcome) (parlora_backend_stop_duration_seconds_sum) / sum by (outcome) (parlora_backend_stop_duration_seconds_count)
1000 * parlora_provider_audio_received_queue_duration_seconds_sum / parlora_provider_audio_received_queue_duration_seconds_count
sum by (source, type, stage) (parlora_runtime_event_count_total)
```

The reporter stores durations in seconds with `_seconds` names; these duration
queries multiply by 1000 for display. The Collector adds `_total` to counter names.
Audio queue and scheduling graphs need the workload below: the single-session
demo does not feed the provider output buffer. Queue distributions are weighted
by observations, not by call. No session or request ID becomes a metric label.

In VictoriaTraces, use this trace query to select the example service:

```text
"resource_attr:service.name":="parlora-observability-demo"
```

Session, startup, policy, queue, backend, delivery and shutdown spans share a
trace. Expand a row to inspect its `trace_id` and operational attributes. To
inspect one trace, replace `TRACE_ID` below with that value and choose **Table**.
The query converts stored nanosecond durations to milliseconds:

```text
trace_id:TRACE_ID
| math duration / 1000000 as duration_ms
| fields _time, name, duration_ms, span_id, parent_span_id, "span_attr:parlora.outcome"
```

The bridge creates session roots. It does not inherit a host request's trace
context; applications with existing distributed traces must associate that
context explicitly. Its queues and active spans are bounded, and unclosed spans
expire. Exporting diagnostics can be dropped under pressure without blocking a
session.

## Generate and verify a workload

Stop the demo, then run:

```sh
mix run workload.exs
```

The workload runs 48 offline sessions with 50, 100, 200 and 350 ms backend delays.
Twelve sessions each exercise successful work, failed work, rejected delivery,
and uncertain execution followed by a verified result. It also fills and drains
the actual provider output buffer with 100, 200 and 400 ms of PCM silence.
Failures and delays are injected by the fixtures; no upstream service is called.

After all sessions finish, leave the host running. In another terminal, from
this directory, compare the stored metrics and traces with the raw observations:

```sh
python3 verify_workload.py /tmp/parlora-observability-workload.json
```

The check compares counts, sums, histogram buckets, span durations and parentage,
error statuses, and the exclusion of content and ID labels. These finite scenarios
check export correctness, not production latency percentiles.

## Development checks

These host tests run without Docker or export services:

```sh
mix test --warnings-as-errors
```

For a single-session ingestion check, keep `mix run demo.exs` running and use its
printed ID:

```sh
python3 check.py --session-id THE_ID_PRINTED_BY_THE_DEMO
```

To exercise an export outage, stop only the Collector and restart the demo.
Session completion should still print while export is unavailable:

```sh
docker compose stop collector
# Stop the running demo, then:
mix run demo.exs
# In another terminal, from this directory:
docker compose start collector
python3 check.py --session-id THE_ID_PRINTED_BY_THE_DEMO
```

## Local configuration and shutdown

Docker ports bind to localhost. The host's metrics listener uses port 19100 on
all interfaces so Docker can scrape `host.docker.internal`; run it on a trusted
development machine. Compose supplies the host-gateway mapping on Linux.
Change the host configuration if ports conflict. Image versions are pinned in
`compose.yaml`.

Stop the running Mix command, then stop the services:

```sh
docker compose down
```

Named volumes preserve local data. Use `docker compose down -v` only when you
want to discard it.
