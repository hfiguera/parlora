"""Optional integration assertion against the running development host/stack."""
import argparse
import json
import time
import urllib.parse
import urllib.request


def get(url, params=None):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=3) as response:
        return json.load(response)


def check(session_id=None):
    metrics = get("http://localhost:18428/api/v1/query", {
        "query": "parlora_session_stop_count_total{outcome=\"closed\"}"
    })
    assert metrics["data"]["result"], "No completed session metric"
    traces = get("http://localhost:19428/select/jaeger/api/traces", {
        "service": "parlora-observability-demo", "limit": 10
    })["data"]
    required = {"parlora.session", "parlora.startup", "parlora.backend_queue",
                "parlora.backend", "parlora.delivery", "parlora.shutdown"}
    matching = [trace for trace in traces if required <= {
        span["operationName"] for span in trace["spans"]}]
    if session_id:
        matching = [trace for trace in matching if any(
            tag["key"] == "parlora.session_id" and tag["value"] == session_id
            for span in trace["spans"] for tag in span.get("tags", []))]
    assert matching, "No complete session trace"
    trace = matching[0]
    root = next(s for s in trace["spans"] if s["operationName"] == "parlora.session")
    assert root["duration"] >= 0
    for span in trace["spans"]:
        assert span["duration"] >= 0
        assert span["startTime"] >= root["startTime"]
        assert span["startTime"] + span["duration"] <= root["startTime"] + root["duration"]
        if span is not root:
            assert any(ref["spanID"] == root["spanID"] for ref in span["references"])
    assert "private-observability-sentinel" not in json.dumps(trace)
    source = urllib.request.urlopen("http://localhost:19100/metrics", timeout=3).read().decode()
    assert "session_id=" not in source and "request_id=" not in source
    assert "private-observability-sentinel" not in source
    print("Metrics ingested; trace parentage and timing verified; content and ID labels absent.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-id", help="Check the exact ID printed by demo.exs")
    args = parser.parse_args()
    deadline = time.monotonic() + 30
    while True:
        try:
            check(args.session_id)
            break
        except (AssertionError, OSError) as error:
            if time.monotonic() >= deadline:
                raise SystemExit(str(error)) from error
            time.sleep(1)
