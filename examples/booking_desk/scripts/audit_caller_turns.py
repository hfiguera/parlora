#!/usr/bin/env python3
"""Check a recorded replay against actual caller-input ticks, without filtering live audio."""
import argparse
import hashlib
import json
from pathlib import Path


def audit(report, max_transcription_delay_ms=3000, max_speech_start_delay_ms=500):
    if report.get("mode") != "replay":
        raise ValueError("Caller timing evidence is available only for scripted replay")
    inputs = [chunk for chunk in report["audio"]["chunks"] if chunk["direction"] == "input"]
    if not inputs or report["audio"]["sample_rate"] != 24000:
        raise ValueError("Expected captured 24kHz replay input")
    windows = []
    for event in report["events"]:
        if event["kind"] == "marker" and event["name"] == "input:caller_started":
            data = event["data"]
            tick, size = data["tick"], data["bytes"]
            if not 0 <= tick < len(inputs) or size <= 0 or size % 2:
                raise ValueError("Invalid caller-input marker")
            start = inputs[tick]["at_ms"]
            windows.append({"label": data["label"], "start_ms": start,
                            "end_ms": start + size / 48})
    if not windows:
        raise ValueError("Actual caller-input onset markers are required")

    turns = {}
    for event in report["events"]:
        if event["kind"] != "event" or event["name"] != "transcript_delta":
            continue
        data = event["data"]
        if data["speaker"] != "user" or not data.get("delta", "").strip():
            continue
        segment = data.get("segment_id")
        if not segment:
            raise ValueError("Caller transcript segments must have identities")
        turn = turns.setdefault(segment, {"segment_id": segment, "first_ms": event["at_ms"],
                                          "last_ms": event["at_ms"], "text": ""})
        turn["last_ms"] = event["at_ms"]
        turn["text"] += data["delta"]

    unexpected = []
    heard = set()
    for turn in turns.values():
        matches = [window for window in windows
                   if window["start_ms"] <= turn["first_ms"]
                   and turn["last_ms"] <= window["end_ms"] + max_transcription_delay_ms]
        if matches:
            heard.update(window["label"] for window in matches)
        else:
            unexpected.append(turn)
    missing = [window["label"] for window in windows if window["label"] not in heard]
    starts = [{"at_ms": event["at_ms"], **event["data"]}
              for event in report["events"]
              if event["kind"] == "event" and event["name"] == "extension"
              and event["data"].get("kind") == "caller_speech"
              and event["data"].get("state") == "started"]
    unexpected_starts = [start for start in starts if not any(
        window["start_ms"] <= start["at_ms"] <= window["end_ms"] + max_speech_start_delay_ms
        for window in windows)]
    interruptions = [{"at_ms": event["at_ms"]} for event in report["events"]
                     if event["kind"] == "event" and event["name"] == "output_interrupted"
                     and event.get("source") == "provider"]
    unexpected_interruptions = [event for event in interruptions if not any(
        window["start_ms"] <= event["at_ms"] <= window["end_ms"] + max_speech_start_delay_ms
        for window in windows)]
    untranscribed_starts = [start for start in starts if start.get("segment_id") not in turns]
    start_ids = {start.get("segment_id") for start in starts}
    missing_starts = [turn for key, turn in turns.items() if key not in start_ids
                      and report.get("provider") == "phonic"]
    boundaries_recorded = bool(starts)
    boundaries_complete = report.get("provider") != "phonic" or boundaries_recorded
    complete = (report["audio"].get("dropped_packets") == 0
                and report.get("event_log", {}).get("dropped_events") == 0)
    discarded = [{"at_ms": event["at_ms"], **event["data"]}
                 for event in report["events"]
                 if event["kind"] == "event" and event["name"] == "extension"
                 and event["data"].get("kind") == "transcript_discarded"]
    return {"passed": (complete and boundaries_complete and not unexpected and not missing
                       and not unexpected_starts and not unexpected_interruptions
                       and not untranscribed_starts and not missing_starts),
            "method": "caller speech starts and transcripts within captured clips plus bounded delays",
            "max_transcription_delay_ms": max_transcription_delay_ms,
            "max_speech_start_delay_ms": max_speech_start_delay_ms,
            "complete_capture": complete, "caller_turns": len(turns),
            "speech_boundaries_recorded": boundaries_recorded,
            "caller_speech_starts": len(starts),
            "unexpected_speech_starts": unexpected_starts,
            "output_interruptions": len(interruptions),
            "unexpected_output_interruptions": unexpected_interruptions,
            "untranscribed_speech_starts": untranscribed_starts,
            "caller_turns_without_speech_starts": missing_starts,
            "unexpected_caller_turns": unexpected, "untranscribed_clips": missing,
            "discarded_non_speech_transcripts": discarded,
            "caller_windows": windows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    source = (args.directory / "session.json").read_bytes()
    result = audit(json.loads(source))
    result["session_sha256"] = hashlib.sha256(source).hexdigest()
    result["auditor_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (args.directory / "caller-turn-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
