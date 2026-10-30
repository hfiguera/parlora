"""Check Phonic's saved end classifications for shutdown_live.exs probes."""
import argparse
import datetime
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path


def verify(rows):
    results = []
    for row in rows:
        endpoint = "https://api.phonic.ai/v1/conversations/" + row["conversation_id"]
        request = urllib.request.Request(
            endpoint, headers={"Authorization": "Bearer " + os.environ["PHONIC_API_KEY"]}
        )
        deadline = time.monotonic() + 10
        while True:
            with urllib.request.urlopen(request, timeout=10) as response:
                conversation = json.load(response)["conversation"]
            ended = conversation.get("ended_at")
            if (ended and conversation.get("ended_by")) or time.monotonic() >= deadline:
                break
            time.sleep(0.25)
        ended_ms = (
            datetime.datetime.fromisoformat(ended.replace("Z", "+00:00")).timestamp() * 1000
            if ended else None
        )
        delay = round(ended_ms - row["client_closed_at_ms"]) if ended_ms else None
        results.append({
            **row, "ended_at": ended, "ended_by": conversation.get("ended_by"),
            "server_end_delay_ms": delay,
            "passed": conversation.get("ended_by") == "user"
            and delay is not None and -1000 <= delay < 5000
            and row["close_call_ms"] < 1000,
        })
    # Both supported codecs must be exercised three times; incomplete evidence fails.
    complete = len(rows) == 6 and all(
        sum(row["codec"] == codec for row in rows) == 3 for codec in ["pcm", "pcmu"]
    )
    return {"passed": complete and all(row["passed"] for row in results), "runs": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify(json.loads(args.report.read_text()))
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Phonic API request failed: HTTP {error.code}") from None
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    raise SystemExit(0 if result["passed"] else 1)
