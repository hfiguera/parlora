"""Check persisted aggregates and every workload span against raw observations."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import time
import urllib.parse
import urllib.request


def get(url, **params):
    with urllib.request.urlopen(url + "?" + urllib.parse.urlencode(params), timeout=10) as r:
        return json.load(r)


def query(expression):
    return get("http://localhost:18428/api/v1/query", query=expression, nocache=1)["data"]["result"]


def verify(evidence):
    run_ids = {r["session_id"] for r in evidence["runs"]}
    scale = evidence["native_per_second"]
    observations = evidence["observations"]
    stops = [o for o in observations if o["event"].endswith(".stop")]
    expected = defaultdict(list)
    for o in stops:
        _, operation, _ = o["event"].split(".")
        expected[(operation, o["metadata"]["outcome"])].append(o["measurements"]["duration"] / scale)

    for (operation, outcome), durations in expected.items():
        selector = '{outcome="' + outcome + '"}'
        prefix = "parlora_" + operation + "_stop_"
        for suffix, value in [("count_total", len(durations)),
                              ("duration_seconds_count", len(durations)),
                              ("duration_seconds_sum", sum(durations))]:
            series = query(prefix + suffix + selector)
            assert len(series) == 1, (prefix + suffix, series)
            assert math.isclose(float(series[0]["value"][1]), value, abs_tol=1e-9), (prefix + suffix, value, series)
        for bucket in query(prefix + "duration_seconds_bucket" + selector):
            upper = float(bucket["metric"]["le"])
            assert int(float(bucket["value"][1])) == sum(d <= upper for d in durations), (operation, outcome, upper)

    runtime = Counter((o["metadata"]["source"], o["metadata"]["type"], o["metadata"].get("stage", "none"))
                      for o in observations if o["event"] == "parlora.runtime.event")
    for (source, kind, stage), count in runtime.items():
        selector = '{source="' + source + '",type="' + kind + '",stage="' + stage + '"}'
        result = query("parlora_runtime_event_count_total" + selector)
        assert len(result) == 1 and int(float(result[0]["value"][1])) == count, (selector, count, result)

    # Check the real queue probes and actual pipeline ticks in the same units
    # exposed to VictoriaMetrics. Queue distributions pool observations, not calls.
    audio = defaultdict(list)
    for o in observations:
        m = o["measurements"]
        if o["event"] == "parlora.provider.audio_received":
            audio[("parlora_provider_audio_received_queue_duration_seconds", "")].append(m["queue_duration_us"] / 1e6)
            audio[("parlora_provider_audio_received_queue_bytes", "")].append(m["queue_bytes"])
        elif o["event"] == "parlora.provider.audio_read":
            audio[("parlora_provider_audio_read_oldest_age_seconds", "")].append(m["oldest_age_us"] / 1e6)
        elif o["event"] == "parlora.audio.tick":
            selector = '{direction="' + o["metadata"]["direction"] + '"}'
            audio[("parlora_audio_tick_late_seconds", selector)].append(m["late_us"] / 1e6)
    received = [o["measurements"] for o in observations if o["event"] == "parlora.provider.audio_received"]
    assert Counter(m["queue_duration_us"] for m in received) == {100_000: 16, 200_000: 16, 400_000: 16}
    assert all(m["queue_bytes"] == m["queue_duration_us"] * 48_000 / 1e6 for m in received)
    assert len(received) == 48 and len(run_ids) == 48
    for (metric, selector), values in audio.items():
        for suffix, value in [("_count", len(values)), ("_sum", sum(values))]:
            result = query(metric + suffix + selector)
            assert len(result) == 1 and math.isclose(float(result[0]["value"][1]), value, abs_tol=1e-9), (metric, value, result)
        for bucket in query(metric + "_bucket" + selector):
            upper = float(bucket["metric"]["le"])
            assert int(float(bucket["value"][1])) == sum(v <= upper for v in values), (metric, upper)

    traces = get("http://localhost:19428/select/jaeger/api/traces",
                 service="parlora-observability-demo", limit=100, lookback="1h")["data"]
    matching = {}
    by_operation = {}
    error_spans = 0
    for trace in traces:
        roots = [s for s in trace["spans"] if s["operationName"] == "parlora.session"]
        if len(roots) != 1:
            continue
        root = roots[0]
        tags = {t["key"]: t["value"] for t in root["tags"]}
        sid = tags.get("parlora.session_id")
        if sid not in run_ids:
            continue
        assert sid not in matching, ("Duplicate session trace", sid)
        matching[sid] = trace["traceID"]
        for span in trace["spans"]:
            attrs = {t["key"]: t["value"] for t in span["tags"]}
            opid = attrs["parlora.operation_id"]
            assert opid not in by_operation
            by_operation[opid] = span
            assert span["duration"] >= 0
            assert span["startTime"] >= root["startTime"]
            assert span["startTime"] + span["duration"] <= root["startTime"] + root["duration"]
            if span is not root:
                assert any(r["spanID"] == root["spanID"] for r in span["references"])
            if attrs.get("parlora.outcome") in ["failed", "error", "timeout"]:
                assert attrs.get("error") in [True, "true"], ("Missing error status", attrs)
                error_spans += 1
            if attrs.get("parlora.outcome") in ["uncertain", "rejected", "superseded"]:
                assert attrs.get("error") not in [True, "true"], ("Expected outcome marked as error", attrs)
            for event in span.get("logs", []):
                assert span["startTime"] <= event["timestamp"] <= span["startTime"] + span["duration"]

    assert set(matching) == run_ids, ("Missing session traces", run_ids - set(matching))
    assert len(by_operation) == len(stops), (len(by_operation), len(stops))
    for o in stops:
        span = by_operation[o["metadata"]["operation_id"]]
        # The Jaeger API represents times in whole microseconds; OTLP uses nanoseconds.
        assert abs(span["duration"] - o["measurements"]["duration"] * 1e6 / scale) <= 1.01
        attrs = {t["key"]: t["value"] for t in span["tags"]}
        assert attrs["parlora.outcome"] == o["metadata"]["outcome"]

    for series in query('{__name__=~"parlora_.*"}'):
        assert not any(key.endswith("_id") for key in series["metric"]), series["metric"]
    assert "private-observability-sentinel" not in json.dumps(traces)
    summary = {"sessions": len(matching), "spans": len(by_operation), "error_spans": error_spans,
               "operation_outcome_groups": len(expected), "runtime_groups": len(runtime), "audio_groups": len(audio),
               "queue_probe_count": len(received),
               "backend_outcomes": {outcome: len(values) for (op, outcome), values in expected.items() if op == "backend"},
               "backend_mean_ms": {outcome: sum(values) / len(values) * 1000 for (op, outcome), values in expected.items() if op == "backend"},
               "checks": "Exact counts, sums, all histogram buckets, outcome groups, parentage, durations, statuses, event containment and privacy passed."}
    print(json.dumps(summary, indent=2))
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text())
    deadline = time.monotonic() + 30
    while True:
        try:
            summary = verify(evidence)
            args.evidence.with_suffix(".verified.json").write_text(json.dumps(summary, indent=2))
            break
        except (AssertionError, OSError) as error:
            if time.monotonic() >= deadline:
                raise SystemExit(str(error)) from error
            time.sleep(1)
