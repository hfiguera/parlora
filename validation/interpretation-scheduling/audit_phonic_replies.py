"""Audit synthetic Phonic status/items replies independently of backend assertions."""
import argparse
import json
from pathlib import Path


def audit(rows):
    epoch = 0
    speech_epoch = None
    text = ""
    answered = False
    violations = []
    answers = 0
    for row in rows:
        payload = row["payload"]
        if row.get("provider") and isinstance(payload, dict):
            if row["direction"] == "event" and payload.get("type") == "user_started_speaking":
                epoch += 1
                text, speech_epoch, answered = "", None, False
            if row["direction"] == "transmit" and payload.get("type") == "generate_reply" and answered:
                violations.append({"at_ms": row["ms"], "context_epoch": epoch})
        if row.get("source") != "provider":
            continue
        if row.get("type") == "context_submitted":
            epoch += 1
            answered = False
        elif row.get("type") == "provider_speech":
            if payload["state"] == "speaking":
                text, speech_epoch = "", epoch
            elif speech_epoch == epoch and any(fact in text.lower() for fact in ["out for delivery", "desk lamp"]):
                answered = True
                answers += 1
                speech_epoch = None
        elif row.get("type") == "transcript_delta" and payload.get("speaker") == "assistant":
            text += payload["delta"]
    return {"completed_status_or_items_answers": answers, "extra_reply_requests": violations}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--expect-violation", action="store_true")
    args = parser.parse_args()
    result = audit(json.loads(args.trace.read_text())["rows"])
    print(json.dumps(result))
    found = bool(result["extra_reply_requests"])
    # At least two business answers ensure an empty/incomplete trace cannot pass.
    raise SystemExit(0 if found == args.expect_violation and result["completed_status_or_items_answers"] >= 2 else 1)
