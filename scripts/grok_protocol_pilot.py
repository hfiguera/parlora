#!/usr/bin/env python3
"""Bounded synthetic Grok protocol evidence, with no saved credentials or audio.

Requires websockets==15.0.1, macOS say, and ffmpeg. Outputs only synthetic
transcripts, event metadata, and counts. This is not human/PSTN qualification.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from datetime import datetime, timezone

from websockets.asyncio.client import connect

MODEL = "grok-voice-3.0"
FUNCTION = "delegate_to_backend"
PROMPT = """You are a concise voice assistant in a synthetic protocol test.
Call delegate_to_backend for order lookups and corrections. Never invent order
facts. Continue conversing while backend work is pending: answer unrelated
questions immediately without repeating the lookup. A correction supersedes the
earlier order. Announce only current verified results. Use one short sentence.
"""


def credential():
    key = os.environ.get("XAI_API_KEY")
    if not key:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s",
             "parlora-grok-development", "-w"], capture_output=True, timeout=20
        )
        if result.returncode:
            raise RuntimeError("Keychain credential unavailable")
        key = result.stdout.decode().strip()
    if not key:
        raise RuntimeError("Empty credential")
    return key


def synthesize(text, directory, codec):
    aiff = directory / "speech.aiff"
    raw = directory / "speech.raw"
    subprocess.run(["say", "-v", "Samantha", "-o", str(aiff), text], check=True, timeout=20)
    fmt, rate = ("mulaw", "8000") if codec == "pcmu" else ("s16le", "24000")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(aiff),
                    "-ac", "1", "-ar", rate, "-f", fmt, str(raw)], check=True, timeout=20)
    return raw.read_bytes()


async def probe(args, key, clips):
    start = time.monotonic()
    report = {"schema": 1, "started_at": datetime.now(timezone.utc).isoformat(),
              "model": MODEL, "reasoning_effort": args.reasoning,
              "reported_model": None, "reported_reasoning_effort": None,
              "codec": args.codec, "scenario": args.scenario,
              "followup_delay_seconds": args.followup_delay,
              "backend_delay_seconds": args.backend_delay,
              "synthetic_speech": True, "timeout_seconds": 45,
              "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "events": [], "calls": [], "transcripts": [], "audio_bytes": 0,
              "ready": False, "result_sent_ms": None, "checks": {}}
    tasks = []
    pcmu = args.codec == "pcmu"
    size = 160 if pcmu else 960
    silence = (b"\xff" if pcmu else b"\x00") * size
    pending_audio = bytearray()
    output = {}
    first_call = asyncio.Event()
    first_audio = asyncio.Event()
    finish = asyncio.Event()
    response_active = False
    current_calls = {}
    completed_calls = set()

    def ms():
        return round((time.monotonic() - start) * 1000)

    def record(kind, **fields):
        report["events"].append({"ms": ms(), "type": kind, **fields})

    async with connect("wss://api.x.ai/v1/realtime?model=" + MODEL,
                       additional_headers={"Authorization": "Bearer " + key},
                       open_timeout=15, close_timeout=2, max_size=1_048_576) as ws:
        async def send(event):
            await ws.send(json.dumps(event))
            record("client:" + event["type"])

        async def speak(name):
            record("synthetic_input", clip=name)
            pending_audio.extend(clips[name])
            while pending_audio:
                await asyncio.sleep(.02)
            record("synthetic_input_finished", clip=name)

        async def pump():
            while not finish.is_set():
                data = bytes(pending_audio[:size])
                del pending_audio[:size]
                data += silence[:size - len(data)]
                await ws.send(json.dumps({"type": "input_audio_buffer.append",
                                          "audio": base64.b64encode(data).decode()}))
                await asyncio.sleep(.02)

        async def results():
            await first_call.wait()
            await asyncio.sleep(args.backend_delay if args.scenario != "baseline" else 1)
            # Close obsolete calls without submitting obsolete business facts.
            for call_id, request in list(current_calls.items()):
                if call_id in completed_calls:
                    continue
                corrected = args.scenario == "correction"
                obsolete = corrected and "124" not in request
                body = {"status": "superseded"} if obsolete else {
                    "result": "Order 124 is out for delivery." if corrected else
                    "Order 123 has shipped; estimated delivery Friday."}
                await send({"type": "conversation.item.create", "item": {
                    "type": "function_call_output", "call_id": call_id,
                    "output": json.dumps(body)}})
            report["result_sent_ms"] = ms()
            # Generation is independent of client playback. Wait for generation
            # idle; the production adapter still needs its own playback policy.
            while response_active:
                await asyncio.sleep(.02)
            await send({"type": "response.create"})

        async def followup():
            if args.scenario == "interruption":
                await first_audio.wait()
                await asyncio.sleep(.1)
                await speak("stop")
                return
            await first_call.wait()
            await asyncio.sleep(args.followup_delay)
            if args.scenario == "pending":
                await speak("question")
            elif args.scenario == "independent":
                await speak("independent")
            elif args.scenario == "correction":
                await speak("correction")

        audio_format = {"type": "audio/pcmu"} if pcmu else {
            "type": "audio/pcm", "rate": 24000}
        await send({"type": "session.update", "session": {
            "voice": "eve", "reasoning": {"effort": args.reasoning},
            "instructions": PROMPT + (" In this test 'also' starts an independent lookup: keep 123 pending while checking 124. Announce each result separately when it arrives."
                                      if args.scenario == "independent" else ""),
            "turn_detection": {"type": "server_vad"},
            "audio": {"input": {"format": audio_format,
                                "transcription": {"model": "grok-transcribe"}},
                      "output": {"format": audio_format}},
            "tools": [{"type": "function", "name": FUNCTION,
                       "description": "Ask the application to handle a caller order lookup or correction.",
                       "parameters": {"type": "object", "properties": {
                           "request": {"type": "string"}}, "required": ["request"]}}]}})
        try:
            async with asyncio.timeout(45):
                async for raw in ws:
                    event = json.loads(raw)
                    kind = event.get("type", "unknown")
                    if kind in ["response.audio.delta", "response.output_audio.delta"]:
                        report["audio_bytes"] += len(base64.b64decode(event["delta"]))
                        if not first_audio.is_set():
                            record("first_audio", response_id=event.get("response_id"))
                            first_audio.set()
                        continue
                    if kind in ["response.audio_transcript.delta", "response.output_audio_transcript.delta"]:
                        rid = event.get("response_id", "unknown")
                        output[rid] = output.get(rid, "") + event["delta"]
                        continue
                    if kind == "conversation.item.input_audio_transcription.updated":
                        continue
                    details = {}
                    if kind == "session.updated" and not report["ready"]:
                        session = event.get("session", {})
                        report["reported_model"] = session.get("model")
                        report["reported_reasoning_effort"] = session.get("reasoning", {}).get("effort")
                        if (report["reported_model"] != MODEL or
                                report["reported_reasoning_effort"] != args.reasoning):
                            report["provider_error"] = {"code": "configuration_mismatch"}
                            record(kind, model=report["reported_model"],
                                   reasoning_effort=report["reported_reasoning_effort"])
                            break
                        report["ready"] = True
                        tasks.extend([asyncio.create_task(pump()), asyncio.create_task(followup())])
                        if args.scenario == "interruption":
                            await send({"type": "conversation.item.create", "item": {
                                "type": "message", "role": "user", "content": [{
                                    "type": "input_text", "text":
                                    "For this test override brevity: count aloud from one to one hundred."}]}})
                            await send({"type": "response.create"})
                        else:
                            tasks.extend([asyncio.create_task(speak("lookup")),
                                          asyncio.create_task(results())])
                    elif kind == "response.created":
                        response_active = True
                    elif kind == "response.done":
                        response_active = False
                        rid = event.get("response", {}).get("id", "unknown")
                        text = output.get(rid, "")
                        details = {"status": event.get("response", {}).get("status"),
                                   "transcript": text}
                        report["transcripts"].append({"ms": ms(), "text": text})
                        if report["result_sent_ms"] and text and (args.scenario != "independent" or "friday" in text.lower()):
                            finish.set()
                        if args.scenario == "interruption" and "hello" in text.lower():
                            finish.set()
                    elif kind == "response.function_call_arguments.done":
                        request = json.loads(event["arguments"]).get("request", "")
                        current_calls[event["call_id"]] = request
                        details = {"name": event.get("name"), "request": request,
                                   "response_id": event.get("response_id")}
                        report["calls"].append({"ms": ms(), **details})
                        first_call.set()
                        if args.scenario == "independent" and "124" in request:
                            async def fast_result(call_id):
                                await asyncio.sleep(1)
                                await send({"type": "conversation.item.create", "item": {
                                    "type": "function_call_output", "call_id": call_id,
                                    "output": json.dumps({"result": "Order 124 is out for delivery."})}})
                                completed_calls.add(call_id)
                                while response_active:
                                    await asyncio.sleep(.02)
                                await send({"type": "response.create"})
                            tasks.append(asyncio.create_task(fast_result(event["call_id"])))
                    elif kind == "conversation.item.input_audio_transcription.completed":
                        details = {"transcript": event.get("transcript"),
                                   "item_id": event.get("item_id")}
                    elif kind == "input_audio_buffer.committed":
                        details = {"item_id": event.get("item_id")}
                    elif kind == "error":
                        details = {"code": event.get("error", {}).get("code")}
                        report["provider_error"] = details
                        finish.set()
                    record(kind, **details)
                    if finish.is_set():
                        break
        except TimeoutError:
            report["timeout"] = True
        finally:
            finish.set()
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    spoken = " ".join(t["text"] for t in report["transcripts"]).lower()
    result_at = report["result_sent_ms"] or float("inf")
    report["checks"] = {
        "configured": report["ready"], "tool_called": bool(report["calls"]),
        "audio_received": report["audio_bytes"] > 0,
        "current_result_spoken": ("out for delivery" if args.scenario == "correction"
                                   else "friday") in spoken,
    }
    if args.scenario == "pending":
        report["checks"]["answered_while_pending"] = any(
            "paris" in t["text"].lower() and t["ms"] < result_at
            for t in report["transcripts"])
    if args.scenario == "correction":
        report["checks"]["replacement_called_before_result"] = any(
            "124" in c["request"] and c["ms"] < result_at for c in report["calls"])
        report["checks"]["no_obsolete_result_spoken"] = "friday" not in spoken
    if args.scenario == "interruption":
        report["checks"] = {"configured": report["ready"],
                            "audio_received": report["audio_bytes"] > 0,
                            "interruption_detected": any(e["type"] == "input_audio_buffer.speech_started"
                                                         for e in report["events"]),
                            "fresh_answer_spoken": "hello" in spoken}
    if args.scenario == "independent":
        report["checks"]["independent_result_while_original_pending"] = any(
            "out for delivery" in t["text"].lower() and t["ms"] < result_at
            for t in report["transcripts"])
    report["checks"]["model_verified"] = report["reported_model"] == MODEL
    report["checks"]["reasoning_verified"] = report["reported_reasoning_effort"] == args.reasoning
    report["passed"] = all(report["checks"].values()) and not report.get("provider_error")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=["baseline", "pending", "correction", "interruption", "independent"], required=True)
    parser.add_argument("--codec", choices=["pcm", "pcmu"], default="pcm")
    parser.add_argument("--reasoning", choices=["high", "none"], default="high")
    parser.add_argument("--followup-delay", type=float, default=1)
    parser.add_argument("--backend-delay", type=float, default=12)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Use a new evidence output path")
    key = credential()
    # Key only lives in memory and this process's environment, never argv/files.
    os.environ["XAI_API_KEY"] = key
    with tempfile.TemporaryDirectory(prefix="parlora-grok-audio-") as tmp:
        directory = Path(tmp)
        clips = {name: synthesize(text, directory, args.codec) for name, text in {
            "lookup": "Please check the status of order one two three.",
            "question": "While you check that, what is the capital of France?",
            "correction": "Cancel that lookup. I meant order one two four instead.",
            "independent": "Also look up order one two four.",
            "stop": "Stop. Just say hello."
        }.items()}
        report = asyncio.run(probe(args, key, clips))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "passed": report["passed"],
                      "checks": report["checks"], "transcripts": report["transcripts"]}))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
