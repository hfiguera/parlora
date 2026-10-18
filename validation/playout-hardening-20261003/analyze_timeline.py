"""Summarize opt-in numeric timing traces without assigning concealment a cause.

Receiver intervals are poll windows, not exact event times. Server and receiver
clocks are independent; the run acknowledgment only bounds their offset.
"""
import argparse
import json
import pathlib
import sys


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return {"count": len(values), "max": values[-1],
            "p99": values[int(.99 * (len(values) - 1))]}


def analyze(directory, trace_path):
    browser = json.loads((directory / "browser.json").read_text())
    trace = json.loads(trace_path.read_text())
    starts = [r["measurements"]["at_us"] for r in trace["rows"] if r["kind"] == "run"]
    if len(starts) != 1:
        raise ValueError("Expected exactly one server run marker")
    start = starts[0]
    rows = [r for r in trace["rows"] if r["measurements"]["at_us"] >= start]
    playout = [r["measurements"] for r in rows if r["kind"] == "playout"]
    ticks = {}
    for direction in ["input", "output"]:
        samples = [r["measurements"] for r in rows
                   if r["kind"] == "tick" and r.get("direction") == direction]
        ticks[direction] = {field: distribution([s[field] for s in samples])
                            for field in ["work_us", "late_us"]}
    times = [p["at_us"] for p in playout]
    gaps = [b - a for a, b in zip(times, times[1:])]
    warm = next(s for s in browser["warmStats"]
                if s["type"] == "inbound-rtp" and s.get("kind") == "audio")
    final = next(s for s in browser["stats"]
                 if s["type"] == "inbound-rtp" and s.get("kind") == "audio")
    previous = {"at_ms": 0, **warm}
    intervals = []
    receiver = browser.get("receiverTimeline", [])
    for sample in receiver:
        delta = sample["concealedSamples"] - previous["concealedSamples"]
        if delta > 0:
            intervals.append({"from_ms": previous["at_ms"], "to_ms": sample["at_ms"],
                              "concealed_samples": delta})
        previous = sample
    # Final getStats can observe an event after the last periodic poll.
    remainder = final["concealedSamples"] - previous["concealedSamples"]
    if remainder > 0:
        intervals.append({"from_ms": previous["at_ms"], "to_ms": None,
                          "concealed_samples": remainder})
    checks = {"server_trace_complete": not trace["truncated"],
              "receiver_trace_complete": bool(receiver)
              and not browser.get("receiverTimelineTruncated", False)
              and not browser.get("receiverTimelineError"),
              "playout_observed": bool(playout),
              "both_pipelines_observed": all(t["work_us"] for t in ticks.values())}
    report = {"checks": checks, "passed": all(checks.values()),
              "server_rows_seen": trace["seen"], "receiver_rows": len(receiver),
              "run_acknowledgment_ms": browser["serverStartReceivedAtMs"] - browser["runAtMs"],
              "playout_interval_us": distribution(gaps),
              "playout_intervals_over_15ms": sum(g > 15_000 for g in gaps),
              "pipeline": ticks, "concealment_poll_intervals": intervals,
              "steady_concealed_samples": final["concealedSamples"] - warm["concealedSamples"],
              "packet_loss": final["packetsLost"] - warm["packetsLost"],
              "causal_attribution": "unresolved; poll windows and separate clocks are not proof of cause"}
    (directory / "timeline-analysis.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("trace", type=pathlib.Path)
    args = parser.parse_args()
    result = analyze(args.directory, args.trace)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["passed"] else 1)
