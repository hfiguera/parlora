"""Summarize preserved timing evidence; this does not simulate audio playback."""

import json
from pathlib import Path


def summarize(trace):
    gap = trace["gap"]["measurements"]
    events = trace["events"]
    start = gap["started_at_us"]
    received = [e["measurements"] for e in events if e["kind"] == "audio_received"]
    previous = [m for m in received if m["at_us"] < start][-1]
    returned = next(m for m in received if m["at_us"] >= start)
    admitted = next(
        e["measurements"]
        for e in events
        if e["kind"] == "frame" and e["measurements"]["at_us"] >= returned["at_us"]
    )
    assert previous["bytes"] == returned["bytes"] == 4_800
    assert gap["duration_us"] == gap["source_unavailable_us"] + gap["recovery_wait_us"]
    return {
        "gap": trace["gap"]["report_index"],
        "peak_before": gap["peak_before"],
        "peak_after": gap["peak_after"],
        "packet_spacing_ms": (returned["at_us"] - previous["at_us"]) / 1_000,
        "receipt_after_empty_ms": (returned["at_us"] - start) / 1_000,
        "first_admission_after_receipt_ms": (admitted["at_us"] - returned["at_us"]) / 1_000,
        "empty_to_first_source_observation_ms": gap["source_unavailable_us"] / 1_000,
        "recovery_wait_ms": gap["recovery_wait_us"] / 1_000,
        "total_ms": gap["duration_us"] / 1_000,
        "release_reason": gap["recovery_release_reason"],
    }


if __name__ == "__main__":
    report = json.loads(Path(__file__).with_name("trace-excerpts.json").read_text())
    print(json.dumps([summarize(trace) for trace in report["gaps"]], indent=2))
