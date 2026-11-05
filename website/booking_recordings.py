"""Export captured BookingDesk calls without inventing audio or execution timings.

Raw PCM, transcription responses and reports stay in the ignored run directory.
Only the selected MP3 and compact, hash-linked metadata enter the publication.
"""
import argparse
from array import array
from bisect import bisect_right
from collections import Counter
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
import wave

RATE = 24000
FRAME_BYTES = 480
ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def samples(data):
    values = array("h", data)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def pcm(values):
    values = array("h", values)
    if sys.byteorder != "little":
        values.byteswap()
    return values.tobytes()


class Recording:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.report_bytes = (self.directory / "session.json").read_bytes()
        self.report = json.loads(self.report_bytes)
        audio = self.report["audio"]
        if (audio["sample_rate"] != RATE or audio["encoding"] != "pcm_s16le"
                or audio["dropped_packets"] or self.report["event_log"]["dropped_events"]):
            raise ValueError("A publication recording requires complete 24kHz PCM and event capture")
        self.inputs = [c for c in audio["chunks"] if c["direction"] == "input"]
        if not self.inputs:
            raise ValueError("No captured input ticks")
        self.times = [c["at_ms"] for c in self.inputs]
        if self.times != sorted(self.times):
            raise ValueError("Input clock moved backward")
        self.caller = (self.directory / "input.pcm").read_bytes()
        if any(c["bytes"] != FRAME_BYTES or c["offset"] != i * FRAME_BYTES
               for i, c in enumerate(self.inputs)) or len(self.caller) != len(self.inputs) * FRAME_BYTES:
            raise ValueError("Input packets are not contiguous replay ticks")
        raw = (self.directory / "output.pcm").read_bytes()
        output = bytearray(len(self.caller))
        seen = set()
        tick, offset = -1, 0
        self.max_pair_skew_ms = 0
        for chunk in audio["chunks"]:
            if chunk["direction"] == "input":
                tick += 1
                continue
            if (chunk["direction"] != "output" or tick < 0 or tick in seen
                    or chunk["offset"] != offset or not 0 < chunk["bytes"] <= FRAME_BYTES):
                raise ValueError("Output packet ownership or offsets are inconsistent")
            size = chunk["bytes"]
            data = raw[offset:offset + size]
            if len(data) != size:
                raise ValueError("Truncated output PCM")
            output[tick * FRAME_BYTES:tick * FRAME_BYTES + size] = data
            offset += size
            seen.add(tick)
            skew = chunk["at_ms"] - self.times[tick]
            if skew < 0:
                raise ValueError("Output timestamp precedes its owning input tick")
            self.max_pair_skew_ms = max(self.max_pair_skew_ms, skew)
        if offset != len(raw):
            raise ValueError("Unaccounted output PCM")
        self.assistant = bytes(output)
        self.duration_ms = len(self.inputs) * 10
        self.events = self.report["events"]

    def clock(self, at_ms):
        """Locate an event on the captured input sample clock, not a caption clock."""
        index = bisect_right(self.times, at_ms) - 1
        if index < 0:
            return 0
        if index == len(self.times) - 1:
            value = index * 10 + at_ms - self.times[index]
        else:
            span = self.times[index + 1] - self.times[index]
            value = index * 10 + (at_ms - self.times[index]) / span * 10
        return round(min(self.duration_ms, max(0, value)), 3)

    def verify_caller(self, clips):
        """Subtract the declared café loop and recover the original caller bytes."""
        clips = Path(clips)
        manifest_bytes = (clips / "manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        if (manifest["voice_id"] != self.report["caller"]["voice_id"]
                or manifest["model"] != self.report["caller"]["model"]):
            raise ValueError("Caller manifest does not describe this recording")
        foreground = samples(self.caller)
        ambience = self.report.get("ambience")
        if ambience:
            noise_bytes = (self.directory / "ambience.pcm").read_bytes()
            if (sha(noise_bytes) != ambience["pcm_sha256"] or ambience["clipped_samples"]
                    or ambience.get("caller_manifest_sha256") != sha(manifest_bytes)):
                raise ValueError("Ambience provenance, caller reference or clipping check failed")
            noise = samples(noise_bytes)
            phase = ambience.get("start_offset_samples", 0)
            recovered = [value - noise[(i + phase) % len(noise)] for i, value in enumerate(foreground)]
            if any(not -32768 <= value <= 32767 for value in recovered):
                raise ValueError("Recovered foreground is outside the PCM range")
            foreground = array("h", recovered)
        foreground = pcm(foreground)
        by_id = {row["id"]: row for row in manifest["utterances"]}
        expected = bytearray(len(foreground))
        windows, position = [], 0
        for event in self.events:
            if event["kind"] != "marker" or not event["name"].startswith("caller:"):
                continue
            clip_id = event["data"]["clip"]
            row = by_id[clip_id]
            data = (clips / row["file"]).read_bytes()
            if sha(data) != row["sha256"]:
                raise ValueError("Caller synthesis hash changed")
            start = foreground.find(data, position)
            if start < 0 or start % 2:
                raise ValueError(f"Captured caller does not contain the complete {clip_id} clip")
            expected[start:start + len(data)] = data
            windows.append({"label": clip_id, "start": start / 48, "end": (start + len(data)) / 48})
            position = start + len(data)
        if not windows or bytes(expected) != foreground:
            raise ValueError("Unexpected foreground samples outside the scripted caller")
        return {"passed": True, "method": "exact PCM recovery after declared noise subtraction",
                "caller_manifest_sha256": sha(manifest_bytes), "verified_clips": len(windows),
                "windows": windows, "foreground_sha256": sha(foreground)}

    def backend_activity(self):
        jobs, operations = {}, {}
        for event in self.events:
            data, name = event["data"], event["name"]
            at = self.clock(event["at_ms"])
            request = event.get("request_id") or data.get("request_id")
            if name == "task_submitted":
                value = data["input"]
                job = {"id": request, "operation": value["operation"], "submitted": at,
                       "input": {k: value[k] for k in ["date", "clinician", "slot", "change"] if k in value},
                       "delivery": []}
                for previous, binding in operations.items():
                    if binding == data["task_id"] and previous != request:
                        jobs[previous].setdefault("replaced_at", at)
                jobs[request] = job
                operations[request] = data["task_id"]
            elif request in jobs:
                job = jobs[request]
                if name == "parlora.backend.start":
                    job["start"] = at
                    job["_raw_start"] = event["at_ms"]
                elif name in ["parlora.backend.stop", "parlora.backend.exception"]:
                    job.update(end=at, outcome=data.get("outcome", "failed"))
                    if "_raw_start" in job:
                        job["execution_ms"] = round(event["at_ms"] - job.pop("_raw_start"), 3)
                elif name in ["request_completed", "request_failed"] and event.get("source") == "backend":
                    facts = data.get("facts", {})
                    safe = {k: facts[k] for k in ["date", "slots", "clinician_name", "confirmation"] if k in facts}
                    if "patient" in facts:
                        safe["patient_matched"] = True
                    if "insurance" in facts:
                        safe["insurance_confirmed"] = facts["insurance"].get("confirmed", False)
                    if "reminder" in facts:
                        safe["reminder"] = {k: facts["reminder"][k] for k in ["status", "simulated"] if k in facts["reminder"]}
                    job["result"] = {"at": at, "status": data.get("status", "failed"), "facts": safe}
                elif name == "result_delivery":
                    job["delivery"].append({"at": at, "stage": data["stage"]})
                elif name == "stale_result":
                    job["filtered_at"] = at
        for job in jobs.values():
            job.pop("_raw_start", None)
        return list(jobs.values())

    def spans(self):
        pending, spans = {}, []
        lanes = {"parlora.backend": "backend", "parlora.delivery": "delivery",
                 "parlora.policy": "policy", "parlora.startup": "startup"}
        for event in self.events:
            if event["kind"] != "telemetry":
                continue
            name, data, at = event["name"], event["data"], self.clock(event["at_ms"])
            base, _, phase = name.rpartition(".")
            if base in lanes:
                key = (base, data.get("operation_id"))
                if phase == "start":
                    pending[key] = at
                elif phase in ["stop", "exception"] and key in pending:
                    spans.append({"lane": lanes[base], "start": pending.pop(key), "end": at,
                                  "outcome": data.get("outcome", "failed"),
                                  "request": data.get("request_id"), "revision": data.get("task_revision")})
            elif name == "booking_desk.judgment.stop":
                duration = event["measurements"]["duration_us"] / 1000
                spans.append({"lane": "jev", "start": self.clock(event["at_ms"] - duration),
                              "end": at, "outcome": data.get("outcome", "unknown"),
                              "request": data.get("request_id"), "revision": data.get("task_revision")})
        return sorted(spans, key=lambda span: span["start"])

    def markers(self):
        return [{"name": event["name"], "at": self.clock(event["at_ms"]), "data": event["data"]}
                for event in self.events if event["kind"] == "marker" or event["name"] in
                ["task_submitted", "stale_result", "output_interrupted"]]

    def provider_captions(self):
        segments = []
        previous = None
        for event in self.events:
            if event["kind"] != "event" or event["name"] != "transcript_delta":
                continue
            data = event["data"]
            identity = data.get("segment_id")
            at = self.clock(event["at_ms"])
            if (previous is None or previous["speaker"] != data["speaker"]
                    or identity != previous["identity"] or at - previous["end"] > 1500):
                previous = {"speaker": data["speaker"], "identity": identity,
                            "text": "", "start": at, "end": at}
                segments.append(previous)
            row = previous
            row["text"] += data.get("delta", "")
            row["end"] = at
        return [{k: v for k, v in row.items() if k != "identity"} for row in segments]

    def write_audio(self):
        caller, assistant = samples(self.caller), samples(self.assistant)
        stereo = array("h", [0]) * (len(caller) * 2)
        stereo[::2], stereo[1::2] = caller, assistant
        stereo_path = self.directory / "transcription-channels.wav"
        with wave.open(str(stereo_path), "wb") as out:
            out.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
            out.writeframes(pcm(stereo))
        mixed = array("h", ((a + b) // 2 for a, b in zip(caller, assistant)))
        wav = self.directory / "conversation.wav"
        with wave.open(str(wav), "wb") as out:
            out.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
            out.writeframes(pcm(mixed))
        target = self.directory / "conversation.mp3"
        subprocess.run(["ffmpeg", "-y", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(wav),
                        "-map_metadata", "-1", "-c:a", "libmp3lame", "-b:a", "128k", str(target)], check=True)
        return stereo_path, target


def transcribe(stereo_path):
    """Scribe sees separate captured channels; no provider text supplies captions."""
    stereo_path = Path(stereo_path)
    target = stereo_path.parent / "scribe-v2.json"
    provenance = stereo_path.parent / "scribe-input.json"
    params = {"model_id": "scribe_v2", "language_code": "en", "use_multi_channel": "true",
              "multichannel_output_style": "combined", "diarize": "false",
              "timestamps_granularity": "word", "tag_audio_events": "false"}
    signature = {"audio_sha256": sha(stereo_path.read_bytes()), "parameters": params}
    if target.exists():
        if not provenance.exists() or json.loads(provenance.read_text()) != signature:
            raise ValueError("Cached transcription belongs to different audio or parameters")
        return json.loads(target.read_text()), signature
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        raise RuntimeError("ELEVENLABS_API_KEY is required for offline audio transcription")
    boundary = uuid.uuid4().hex
    body = bytearray()
    for name, value in params.items():
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="channels.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode())
    body.extend(stereo_path.read_bytes())
    body.extend(f'\r\n--{boundary}--\r\n'.encode())
    request = urllib.request.Request("https://api.elevenlabs.io/v1/speech-to-text", data=bytes(body),
                                    headers={"xi-api-key": key, "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Audio transcription returned HTTP {error.code}; response suppressed") from None
    parsed = json.loads(raw)
    if "words" not in parsed:
        raise ValueError("Expected a combined multichannel word-timed transcription")
    target.write_bytes(raw)
    provenance.write_text(json.dumps(signature, indent=2) + "\n")
    return parsed, signature


def captions_from_words(words):
    captions = []
    for channel, speaker in [(0, "user"), (1, "assistant")]:
        current = None
        for word in sorted([w for w in words if w.get("type") == "word" and w.get("channel_index") == channel], key=lambda w: w["start"]):
            start, end = round(word["start"] * 1000), round(word["end"] * 1000)
            if current and start - current["end"] > 650:
                captions.append(current)
                current = None
            if current is None:
                current = {"speaker": speaker, "start": start, "end": end, "text": word["text"]}
            else:
                current["text"] += " " + word["text"]
                current["end"] = end
            if re.search(r"[.!?]$", word["text"]) and word["text"].lower() not in ["dr.", "mr.", "ms."]:
                captions.append(current)
                current = None
        if current:
            captions.append(current)
    if any(w.get("type") == "word" and w.get("channel_index") not in [0, 1] for w in words):
        raise ValueError("Transcription words are missing channel identity")
    return sorted(captions, key=lambda c: (c["start"], c["end"]))


def waveform(data, bins=400):
    values = samples(data)
    result = []
    for i in range(bins):
        part = values[i * len(values) // bins:(i + 1) * len(values) // bins]
        rms = math.sqrt(sum(x * x for x in part) / max(1, len(part)))
        result.append(round(min(1, rms / 3000), 4))
    return result


def phonic_caller_audit(recording, integrity):
    if recording.report["provider"] != "phonic":
        return None
    path = ROOT / "examples/booking_desk/scripts/audit_caller_turns.py"
    spec = importlib.util.spec_from_file_location("booking_caller_audit", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    report = recording.report
    if not report.get("ambience"):
        # Clean replay has no recorder onset markers. Exact PCM matching supplies
        # their sample offsets for this offline audit; the captured report stays intact.
        events = list(report["events"])
        for window in integrity["windows"]:
            events.append({"kind": "marker", "name": "input:caller_started", "data": {
                "label": window["label"], "tick": round(window["start"] / 10),
                "bytes": round((window["end"] - window["start"]) * 48)}})
        report = {**report, "events": events}
    result = module.audit(report)
    result.update(onset_evidence="captured onset markers" if report.get("ambience") else "exact caller PCM offsets",
                  auditor_sha256=sha(path.read_bytes()), session_sha256=sha(recording.report_bytes))
    (recording.directory / "caller-turn-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def export(directory, clips, output):
    recording = Recording(directory)
    integrity = recording.verify_caller(clips)
    stereo_path, audio_path = recording.write_audio()
    transcription, transcription_input = transcribe(stereo_path)
    report = recording.report
    activity = recording.backend_activity()
    copied = ["provider", "model", "jev_model", "scenario", "outcome", "passed", "checks", "delays_ms",
              "timezone", "fictional_today", "captured_at", "synthetic_caller", "ambience", "caller",
              "library_source_sha256", "source_sha256", "reminder_jobs", "booking_flow", "opening",
              "readback_evaluator", "identity_extractor", "appointments", "submissions", "provider_options",
              "provider_defaults", "assistant_voice"]
    metadata = {key: report[key] for key in copied if key in report}
    pcms = {"input": sha(recording.caller), "output": sha(recording.assistant)}
    metadata.update(
        audio=Path(output).with_suffix(".mp3").name,
        audio_sha256=sha(audio_path.read_bytes()), duration_ms=recording.duration_ms,
        capture_boundary=report["audio"]["boundary"], mix_gain_per_track=0.5,
        caption_labels={"user": "Caller input" if report.get("ambience") else "Caller", "assistant": "Assistant"},
        captions=captions_from_words(transcription["words"]), provider_captions=recording.provider_captions(),
        spans=recording.spans(), markers=recording.markers(), backend_activity=activity,
        waveforms={"caller": waveform(recording.caller), "assistant": waveform(recording.assistant)},
        waveform_source={"kind": "separate_captured_pcm", "method": "rms", "bins": 400,
                         "display_rms_scale": 3000, "mix_gain_per_track": 0.5, "pcm_sha256": pcms},
        caption_source={"model": "scribe_v2", "kind": "offline_audio_transcription", "timing": "audio_word",
                        "speaker_mapping": {"0": "caller", "1": "assistant"}, "pcm_sha256": pcms,
                        "report_sha256": sha(recording.report_bytes),
                        "response_sha256": sha((recording.directory / "scribe-v2.json").read_bytes()),
                        "input_audio_sha256": transcription_input["audio_sha256"]},
        reconstruction={"version": 3, "clock": "shared_240_sample_ticks", "output_alignment": "ordered tick pairs",
                        "event_alignment": "interpolation on captured input ticks",
                        "max_pair_skew_ms": recording.max_pair_skew_ms, "exporter_sha256": sha(Path(__file__).read_bytes())},
        input_integrity=integrity,
        caller_turn_audit=phonic_caller_audit(recording, integrity),
        metrics={"workflow_checks_passed": sum(report["checks"].values()), "workflow_checks_total": len(report["checks"]),
                 "recorded_duration_ms": recording.duration_ms,
                 "new_bookings": sum(1 for a in report["appointments"] if a[0] != "appt_existing" and a[3] == "booked"),
                 "simulated_reminders": len(report["reminder_jobs"]), "stale_results": report["stale_results"],
                 "backend_operations": dict(Counter(j["operation"] for j in activity)),
                 "backend_execution_ms": [{"operation": j["operation"], "date": j["input"].get("date"),
                                            "duration_ms": j.get("execution_ms")} for j in activity]},
    )
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix(".mp3").write_bytes(audio_path.read_bytes())
    output.with_suffix(".json").write_text(json.dumps(metadata, separators=(",", ":")) + "\n")
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--clips", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="Publication JSON path; MP3 is written beside it")
    args = parser.parse_args()
    metadata = export(args.directory, args.clips, args.output)
    print(json.dumps({"output": str(args.output), "outcome": metadata["outcome"], "metrics": metadata["metrics"]}))


if __name__ == "__main__":
    main()
