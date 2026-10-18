"""Compare retained JEV decisions and deterministic fallback without network access."""
import json
import math
from pathlib import Path

directory = Path(__file__).parent
summary = {}
for variant in ("v1", "v2"):
    rows = json.loads((directory / f"pilot-{variant}.json").read_text())["rows"]
    times = sorted(row["elapsed_ms"] for row in rows)

    def suppresses(row):
        if row["result"] in ("covered", "different"):
            return row["result"] == "covered"
        return row["baseline_suppresses"]

    result = {
        "total": len(rows),
        "exact_labels": sum(row["passed"] for row in rows),
        "confident_false_suppression": [
            row["id"] for row in rows
            if row["result"] == "covered" and row["expected"] != "covered"
        ],
        "abstentions": sum(row["result"] == "uncertain" for row in rows),
        "errors": sum(row["result"] == "error" for row in rows),
        "median_ms": times[len(times) // 2],
        "p95_ms": times[math.ceil(0.95 * len(times)) - 1],
        "max_ms": max(times),
        "baseline_decision_correct": sum(
            row["baseline_suppresses"] == (row["expected"] == "covered") for row in rows
        ),
        "jev_with_fallback_decision_correct": sum(
            suppresses(row) == (row["expected"] == "covered") for row in rows
        ),
        "fallback_false_suppression": [
            row["id"] for row in rows if suppresses(row) and row["expected"] != "covered"
        ],
    }
    result["gate_passed"] = (
        not result["confident_false_suppression"]
        and not result["fallback_false_suppression"]
        and result["jev_with_fallback_decision_correct"] > result["baseline_decision_correct"]
        and result["max_ms"] < 700
    )
    summary[variant] = result

(directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
