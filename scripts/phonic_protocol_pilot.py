#!/usr/bin/env python3
"""Bounded synthetic Phonic-1 wire probes; never save credentials or audio.

Run with websockets==15.0.1, macOS say, and ffmpeg. This is protocol evidence,
not a human-call qualification or an assertion of physical playback.
"""
import argparse
import asyncio
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import time

from websockets.asyncio.client import connect

FUNCTION = "delegate_to_backend"
PROMPT = """You are a concise voice assistant in a synthetic protocol test.
Call delegate_to_backend for order lookups and corrections. Never invent order
facts. Continue answering unrelated questions while backend work is pending.
A correction replaces the previous request. Announce only the current verified
result. Never repeat work because a result is delayed. Speak briefly in English.
"""


def synthesize(text, directory, codec):
    source, target = directory / "speech.aiff", directory / "speech.raw"
    subprocess.run(["say", "-v", "Samantha", "-o", str(source), text],
                   check=True, timeout=20, capture_output=True)
    fmt, rate = ("mulaw", "8000") if codec == "pcmu" else ("s16le", "24000")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(source),
                    "-ac", "1", "-ar", rate, "-f", fmt, str(target)],
                   check=True, timeout=20, capture_output=True)
    return target.read_bytes()


async def probe(args, clips):
    key = os.environ.get("PHONIC_API_KEY")
    if not key:
        raise RuntimeError("PHONIC_API_KEY is required; use scripts/with_keychain.py")
    origin = time.monotonic()
    report = {"schema": 1, "started_at": datetime.now(timezone.utc).isoformat(),
              "model": "phonic-1", "codec": args.codec, "scenario": args.scenario,
              "retention": args.retention,
              "synthetic_speech": True, "timeout_seconds": args.timeout,
              "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "events": [], "calls": [], "transcripts": [], "audio_bytes": 0,
              "ready": False, "checks": {}}
    size = 160 if args.codec == "pcmu" else 960
    silence = (b"\xff" if args.codec == "pcmu" else b"\x00") * size
    pending = bytearray()
    first_call, first_audio, finished = asyncio.Event(), asyncio.Event(), asyncio.Event()
    caller_speaking = assistant_speaking = False
    conversation_id = None
    calls, completed = {}, set()
    tasks = []
    result_sent_at = None
    reply_requested_at = None

    def record(kind, **fields):
        report["events"].append({"ms": round((time.monotonic() - origin) * 1000),
                                 "type": kind, **fields})

    async def session(url, reconnect=False):
        nonlocal caller_speaking, assistant_speaking, conversation_id, result_sent_at, reply_requested_at
        async with connect(url, additional_headers={"Authorization": "Bearer " + key},
                           open_timeout=15, close_timeout=2, max_size=1_048_576) as ws:
            async def send(message):
                await ws.send(json.dumps(message))
                record("client:" + message["type"])

            async def pump():
                while not finished.is_set():
                    data = bytes(pending[:size])
                    del pending[:size]
                    data += silence[:size - len(data)]
                    await ws.send(json.dumps({"type": "audio_chunk",
                                              "audio": base64.b64encode(data).decode()}))
                    await asyncio.sleep(.02)

            async def speak(name):
                record("synthetic_input", clip=name)
                pending.extend(clips[name])
                while pending and not finished.is_set():
                    await asyncio.sleep(.02)
                record("synthetic_input_finished", clip=name)

            async def followup():
                if args.scenario == "interruption":
                    await first_audio.wait()
                    await asyncio.sleep(.15)
                    await speak("stop")
                elif args.scenario in {"correction", "pending"}:
                    await first_call.wait()
                    await asyncio.sleep(1)
                    await speak("correction" if args.scenario == "correction" else "question")

            async def results():
                nonlocal result_sent_at, reply_requested_at
                await first_call.wait()
                await asyncio.sleep(8 if args.scenario != "baseline" else 1)
                for call_id, request in list(calls.items()):
                    if call_id in completed:
                        continue
                    obsolete = args.scenario == "correction" and "124" not in request
                    output = {"status": "superseded", "instruction": "Do not announce obsolete results."} if obsolete else {
                        "result": "Order 124 is out for delivery." if args.scenario == "correction" else
                        "Order 123 has shipped; estimated delivery Friday."}
                    await send({"type": "tool_call_output", "tool_call_id": call_id,
                                "output": output})
                    completed.add(call_id)
                result_sent_at = time.monotonic()
                report["result_sent_ms"] = round((result_sent_at - origin) * 1000)
                while caller_speaking or assistant_speaking:
                    await asyncio.sleep(.02)
                reply_requested_at = time.monotonic()
                await send({"type": "generate_reply", "system_message":
                            "Announce only the current verified backend result, briefly. Do not call tools again."})

            if not reconnect:
                fmt = "mulaw_8000" if args.codec == "pcmu" else "pcm_24000"
                config = {"type": "config", "model": "phonic-1", "system_prompt": PROMPT,
                            "input_format": fmt, "output_format": fmt,
                            "stream_ahead_of_real_time": False,
                            "tools": [{"type": "custom_websocket", "execution_mode": "async",
                                       "tool_call_output_timeout_ms": 30000,
                                       "wait_for_response": False,
                                       "require_speech_before_tool_call": False,
                                       "tool_schema": {"type": "function", "function": {
                                           "name": FUNCTION, "description": "Ask the application to handle an order lookup or correction.", "strict": True,
                                           "parameters": {"type": "object", "properties": {
                                               "request": {"type": "string"}}, "required": ["request"],
                                               "additionalProperties": False}}}}]}
                if args.retention == "zero":
                    config["data_retention_policy"] = {"zero_data_retention": True}
                if args.vad_threshold is not None:
                    config["vad_threshold"] = args.vad_threshold
                await send(config)
            async for raw in ws:
                event = json.loads(raw)
                kind = event.get("type", "unknown")
                fields = {}
                if kind == "audio_chunk":
                    report["audio_bytes"] += len(base64.b64decode(event["audio"]))
                    if assistant_speaking:
                        first_audio.set()
                    text = event.get("text", "")
                    if text:
                        report["transcripts"].append({"ms": round((time.monotonic() - origin) * 1000),
                                                      "speaker": "assistant", "text": text})
                    continue
                if kind == "conversation_created":
                    conversation_id = event.get("conversation_id")
                    fields = {"has_conversation_id": bool(conversation_id)}
                elif kind == "ready_to_start_conversation" and not report["ready"]:
                    report["ready"] = True
                    tasks.append(asyncio.create_task(pump()))
                    if args.scenario in {"interruption", "reconnect"}:
                        await send({"type": "generate_reply", "user_message":
                                    "Count aloud from one to one hundred." if args.scenario == "interruption" else "Say hello briefly."})
                    else:
                        tasks.extend([asyncio.create_task(speak("lookup")),
                                      asyncio.create_task(results())])
                    tasks.append(asyncio.create_task(followup()))
                elif kind == "conversation_reconnected":
                    report["reconnected"] = True
                    await send({"type": "generate_reply", "user_message": "Say the word restored."})
                elif kind == "input_text":
                    fields = {"text": event.get("text"), "language": event.get("language")}
                    report["transcripts"].append({"ms": round((time.monotonic() - origin) * 1000),
                                                  "speaker": "user", "text": event.get("text", "")})
                elif kind == "user_started_speaking":
                    caller_speaking = True
                elif kind == "user_finished_speaking":
                    caller_speaking = False
                elif kind == "assistant_started_speaking":
                    assistant_speaking = True
                elif kind in {"assistant_finished_speaking", "interrupted_response", "assistant_chose_not_to_respond"}:
                    assistant_speaking = False
                    if kind == "interrupted_response":
                        fields = {"text": event.get("text")}
                    if kind == "assistant_finished_speaking":
                        if args.scenario == "reconnect" and not reconnect and conversation_id:
                            record("transport_aborted")
                            ws.transport.abort()
                            return conversation_id
                        if reconnect or reply_requested_at or (args.scenario == "interruption" and any(e["type"] == "user_started_speaking" for e in report["events"])):
                            finished.set()
                elif kind == "tool_call":
                    request = event.get("parameters", {}).get("request", "")
                    calls[event["tool_call_id"]] = request
                    report["calls"].append({"ms": round((time.monotonic() - origin) * 1000), "request": request})
                    fields = {"name": event.get("tool_name"), "request": request}
                    first_call.set()
                elif kind == "tool_call_output_processed":
                    fields = {"timed_out": event.get("timed_out"), "error": bool(event.get("error_message"))}
                elif kind in {"error", "warning"}:
                    # Provider error messages and URLs are deliberately excluded.
                    fields = {"parameter_names": list(event.get("param_errors", {})),
                              "parameters": {k: str(v).replace(key, "[REDACTED]")[:500]
                                             for k, v in event.get("param_errors", {}).items()},
                              "message": str(event.get(kind, "")).replace(key, "[REDACTED]")[:500]}
                    if kind == "error":
                        report["provider_error"] = True
                        finished.set()
                record(kind, **fields)
                if finished.is_set():
                    break

    try:
        async with asyncio.timeout(args.timeout):
            conv_id = await session("wss://api.phonic.ai/v1/sts/ws")
            if args.scenario == "reconnect" and conv_id and not finished.is_set():
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                tasks.clear()
                await asyncio.sleep(.5)
                await session("wss://api.phonic.ai/v1/sts/ws?reconnect_conv_id=" + conv_id, reconnect=True)
    except TimeoutError:
        report["timeout"] = True
    except Exception as error:
        report["transport_error"] = type(error).__name__
    finally:
        finished.set()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    spoken = re.sub(r"\s+", " ", "".join(t["text"] for t in report["transcripts"] if t["speaker"] == "assistant")).lower()
    report["checks"] = {"configured": report["ready"], "audio_received": report["audio_bytes"] > 0,
                        "no_provider_error": not report.get("provider_error", False)}
    if args.scenario in {"baseline", "pending", "correction"}:
        report["checks"]["tool_called"] = bool(calls)
        report["checks"]["result_announced"] = ("out for delivery" if args.scenario == "correction" else "friday") in spoken
    if args.scenario == "correction":
        report["checks"]["correction_delegated"] = any("124" in c["request"] for c in report["calls"])
        report["checks"]["no_obsolete_fact"] = "friday" not in spoken
    if args.scenario == "pending":
        report["checks"]["answered_while_pending"] = any("paris" in t["text"].lower() and t["ms"] < report.get("result_sent_ms", 0) for t in report["transcripts"])
    if args.scenario == "interruption":
        report["checks"]["interruption_observed"] = any(e["type"] == "interrupted_response" for e in report["events"])
    if args.scenario == "reconnect":
        report["checks"]["resumed"] = report.get("reconnected", False)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=["baseline", "pending", "correction", "interruption", "reconnect"], default="baseline")
    parser.add_argument("--codec", choices=["pcm", "pcmu"], default="pcm")
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--retention", choices=["provider-default", "zero"], default="provider-default")
    parser.add_argument("--vad-threshold", type=float)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 60:
        parser.error("--timeout must be between 1 and 60 seconds")
    with tempfile.TemporaryDirectory(prefix="phonic-synthetic-") as directory:
        clips = {name: synthesize(text, Path(directory), args.codec) for name, text in {
            "lookup": "Please check order one two three.",
            "correction": "Actually, check order one two four instead.",
            "question": "What is the capital of France?",
            "stop": "Stop counting. Say hello instead."}.items()}
        report = asyncio.run(probe(args, clips))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"scenario": args.scenario, "codec": args.codec, "checks": report["checks"],
                      "provider_error": report.get("provider_error", False),
                      "transport_error": report.get("transport_error"), "report": str(args.output)}))
    if not all(report["checks"].values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
