# Observability development host

This optional checkout-only host exercises the public Parlora telemetry contract
against VictoriaMetrics and VictoriaTraces through an OpenTelemetry Collector.
It is development tooling, not a requirement or dependency of Parlora.

The host owns the metric reporter, HTTP listener, OpenTelemetry SDK/exporter,
buffering and logging configuration. The deterministic session uses the existing
checkout's test adapters. It makes no voice API calls, needs no credentials and
records no audio. It checks plumbing and operation boundaries, not audio quality.

## Run

From this directory:

```sh
docker compose up -d
mix deps.get
mix run demo.exs
```

Keep the command running while inspecting the results. The demo executes one real
Parlora session with deterministic adapters, a policy, backend execution and result
delivery, then keeps the host alive for scraping and asynchronous trace export.
It installs no Jido, Sagents or Legion dependency. The initial build still includes
Parlora's networking dependencies and their native prerequisites; see the public
requirements guide. Device and Opus bindings are disabled for this host.

- Metrics source: http://localhost:19100/metrics
- VictoriaMetrics UI: http://localhost:18428/vmui/
- VictoriaTraces UI: http://localhost:19428/select/vmui/
- Collector health: http://localhost:13133/

Use these MetricsQL queries in VictoriaMetrics:

```promql
parlora_session_stop_count_total
parlora_backend_stop_duration_seconds_sum / parlora_backend_stop_duration_seconds_count
histogram_quantile(0.95, sum(rate(parlora_delivery_stop_duration_seconds_bucket[5m])) by (le))
```

The Collector normalizes counter names with `_total`. Duration histograms are in
seconds, explicitly named `_seconds`; multiply by 1000 when displaying milliseconds. A single demo is enough to check ingestion, not to estimate meaningful
percentiles. Run multiple sessions or use your own host for operational statistics.

Queue sizes, audio ages and playback targets are observation distributions across
sessions, not global last-value gauges. They are weighted by observations, not by
call; do not interpret them as per-call averages or user-perceived latency.
Operation metrics group by bounded outcome; tick lateness groups by direction,
and runtime counters by source, type and stage (`none` when absent). Session,
request and task IDs belong in traces, never metric labels.

For a repeatable workload, stop the demo and run:

```sh
mix run workload.exs
```

This runs 48 real offline sessions with 50, 100, 200 and 350 ms backend delays.
It also probes the actual provider output buffer with 100, 200 and 400 ms of
PCM silence and verifies that it drains. These isolated probes check queue timing,
not model delivery or audible playback. Twelve sessions each exercise successful work, failed work, rejected delivery,
and uncertain execution followed by a verified result. Failure is an injected
backend result, not a real upstream outage. It writes raw timing observations to
`/tmp/parlora-observability-workload.json` and keeps the host running. Verify the
stored metrics and traces against those observations in another terminal:

```sh
python3 verify_workload.py /tmp/parlora-observability-workload.json
```

Useful graph queries (the duration expression is displayed in milliseconds):

```promql
sum by (outcome) (parlora_backend_stop_count_total)
1000 * sum by (outcome) (parlora_backend_stop_duration_seconds_sum) / sum by (outcome) (parlora_backend_stop_duration_seconds_count)
sum by (source, type, stage) (parlora_runtime_event_count_total)
```

In the traces UI, select service `parlora-observability-demo`. Session, startup,
policy, queue, backend, delivery and shutdown spans share a trace and carry IDs as
attributes. They never turn task IDs into metric labels. Continuous voice model
generations and conversational turn times are not fabricated.

The sample bridge creates session roots rather than inheriting an existing host
request trace. Applications with existing distributed traces should explicitly
associate that context with the session. This demo is not a general tracing SDK.

All Docker published ports bind to localhost. The host's metrics listener uses
port 19100 on all interfaces so Docker can scrape `host.docker.internal`; it contains
operational counters only and should be run on a trusted development machine.
On Linux, Compose supplies the host-gateway mapping. Change host-owned config if
these ports conflict. Docker services use the explicitly pinned image versions in
`compose.yaml`; no registry or credentials are needed for telemetry export.

The trace bridge and SDK have finite buffers and discard diagnostics under pressure.
The SDK exports asynchronously; no network operation runs inside a Parlora callback.
Missing stop events can leave spans open, so the development bridge also expires
old spans. Production exporters should monitor their own drop/failure counters.

## Test without Docker

```sh
mix test --warnings-as-errors
```

The ordinary library tests also require no Collector, reporter or Docker:

```sh
cd ../..
mix test --warnings-as-errors
```

For an optional integration check, leave `mix run demo.exs` running and execute:

```sh
python3 check.py --session-id THE_ID_PRINTED_BY_THE_DEMO
```

It waits up to 30 seconds for metrics and traces, verifies their boundaries and
correlation, and checks that request content is absent. To test an outage, stop
only the Collector, restart the demo and verify session completion still prints:

```sh
docker compose stop collector
# Stop the running demo with Ctrl+C, then start it again:
mix run demo.exs
# In another terminal:
docker compose start collector
python3 check.py --session-id THE_ID_PRINTED_BY_THE_DEMO
```

## Stop

Stop the demo with Ctrl+C, then run:

```sh
docker compose down
```

Named volumes keep local evidence. To explicitly discard that local development
data, use `docker compose down -v`.
