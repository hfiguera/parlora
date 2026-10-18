#!/usr/bin/env python3
"""Bounded protocol probe; requires websockets 15 and GEMINI_API_KEY or macOS Keychain.

Records synthetic test transcripts and event metadata, never credentials, audio or
resumption tokens. This probes the wire protocol, not human conversation quality.
"""

import argparse
import asyncio
import base64
import json
import hashlib
from pathlib import Path
from datetime import datetime, timezone
import os
import subprocess
import time
import wave

from websockets.asyncio.client import connect


def credential():
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                "parlora-gemini-development",
                "-w",
            ],
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError("Cannot retrieve Gemini credential")
        key = result.stdout.decode().strip()
    if not key:
        raise RuntimeError("Missing Gemini credential")
    return key


async def probe(
    key,
    version,
    scenario,
    audio,
    manual_vad=False,
    sdk_casing=False,
    thinking="low",
    tool_name="delegate_to_backend",
    correction_audio=None,
):
    started = time.monotonic()
    report = {
        "version": version,
        "scenario": scenario,
        "thinking": thinking,
        "tool_name": tool_name,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "manual_vad": manual_vad,
        "sdk_casing": sdk_casing,
        "events": [],
    }
    url = (
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage."
        + version
        + ".GenerativeService.BidiGenerateContent"
    )
    tasks = []

    def record(event):
        content = event.get("serverContent", {})
        item = {"ms": round((time.monotonic() - started) * 1000), "fields": list(event)}
        item["content_fields"] = list(content)
        item["part_fields"] = [
            list(p) for p in content.get("modelTurn", {}).get("parts", [])
        ]
        for name in (
            "turnComplete",
            "generationComplete",
            "interrupted",
            "interactionStatus",
            "inputTranscription",
            "outputTranscription",
        ):
            if name in content:
                item[name] = content[name]
        if "interactionStatus" in event:
            item["topLevelInteractionStatus"] = event["interactionStatus"]
        item["audio_bytes"] = sum(
            len(base64.b64decode(p["inlineData"]["data"]))
            for p in content.get("modelTurn", {}).get("parts", [])
            if "inlineData" in p
        )
        for name in (
            "toolCall",
            "toolCallCancellation",
            "usageMetadata",
            "goAway",
            "error",
        ):
            if name in event:
                item[name] = event[name]
        item["part_function_calls"] = [
            p["functionCall"]
            for p in content.get("modelTurn", {}).get("parts", [])
            if "functionCall" in p
        ]
        if "sessionResumptionUpdate" in event:
            item["resumable"] = event["sessionResumptionUpdate"].get("resumable")
        report["events"].append(item)

    try:
        async with asyncio.timeout(45):
            async with connect(
                url,
                additional_headers={"x-goog-api-key": key},
                open_timeout=10,
                max_size=2**20,
            ) as ws:

                async def send(value):
                    if sdk_casing and "realtimeInput" in value:
                        value = {"realtime_input": value["realtimeInput"]}
                    await ws.send(json.dumps(value))

                async def prompt(text):
                    await send(
                        {
                            "clientContent": {
                                "turns": [{"role": "user", "parts": [{"text": text}]}],
                                "turnComplete": True,
                            }
                        }
                    )

                async def result(call):
                    await asyncio.sleep(3)
                    order = (
                        "123" if "123" in json.dumps(call.get("args", {})) else "124"
                    )
                    await send(
                        {
                            "toolResponse": {
                                "functionResponses": [
                                    {
                                        "id": call["id"],
                                        "name": call["name"],
                                        "response": {
                                            "result": "Order "
                                            + order
                                            + " is arriving Friday."
                                        },
                                    }
                                ]
                            }
                        }
                    )

                async def stream_audio(path=None, lead_seconds=2):
                    if manual_vad:
                        await send({"realtimeInput": {"activityStart": {}}})
                    with wave.open(path or audio, "rb") as source:
                        rate = source.getframerate()
                        assert source.getnchannels() == 1 and source.getsampwidth() == 2
                        data = (
                            bytes(rate * 2 * lead_seconds)
                            + source.readframes(source.getnframes())
                            + bytes(rate * 2 * 5)
                        )
                        size = rate * 2 // 50
                        report["input_rate"] = rate
                        report["input_audio_bytes"] = len(data)
                        for offset in range(0, len(data), size):
                            chunk = data[offset : offset + size]
                            await send(
                                {
                                    "realtimeInput": {
                                        "audio": {
                                            "mimeType": "audio/pcm;rate=" + str(rate),
                                            "data": base64.b64encode(chunk).decode(),
                                        }
                                    }
                                }
                            )
                            await asyncio.sleep(0.02)
                    if manual_vad:
                        await send({"realtimeInput": {"activityEnd": {}}})
                    else:
                        await silence(rate)

                async def silence(rate=16000):
                    while True:
                        await send(
                            {
                                "realtimeInput": {
                                    "audio": {
                                        "mimeType": "audio/pcm;rate=" + str(rate),
                                        "data": base64.b64encode(
                                            bytes(rate * 2 // 50)
                                        ).decode(),
                                    }
                                }
                            }
                        )
                        await asyncio.sleep(0.02)

                await send(
                    {
                        "setup": {
                            "model": "models/gemini-3.8-live-extended-thinking",
                            "generationConfig": {
                                "responseModalities": ["AUDIO"],
                                "thinkingConfig": {"thinkingLevel": thinking.upper()},
                            },
                            "systemInstruction": {
                                "parts": [
                                    {
                                        "text": "You check orders. Use "
                                        + tool_name
                                        + " for every order lookup. Briefly acknowledge while waiting; speak only verified results. Keep replies under two sentences."
                                    }
                                ]
                            },
                            "tools": [
                                {
                                    "functionDeclarations": [
                                        {
                                            "name": tool_name,
                                            "description": "Request the application's backend to check an order.",
                                            "behavior": "NON_BLOCKING",
                                            "parameters": {
                                                "type": "OBJECT",
                                                "properties": {
                                                    "request": {"type": "STRING"}
                                                },
                                                "required": ["request"],
                                            },
                                        }
                                    ]
                                }
                            ],
                            "inputAudioTranscription": {},
                            "outputAudioTranscription": {},
                            "realtimeInputConfig": {
                                "automaticActivityDetection": {
                                    "disabled": manual_vad,
                                    "silenceDurationMs": 700,
                                }
                            },
                            "sessionResumption": {},
                            "contextWindowCompression": {"slidingWindow": {}},
                        }
                    }
                )
                first_call = True
                input_task = None
                async for raw in ws:
                    event = json.loads(raw)
                    record(event)
                    if "setupComplete" in event:
                        report["setup_ok"] = True
                        if scenario in ("audio", "audio-cancel"):
                            input_task = asyncio.create_task(stream_audio())
                            tasks.append(input_task)
                        else:
                            tasks.append(asyncio.create_task(silence()))
                            await prompt("Check order 124.")
                    for call in event.get("toolCall", {}).get("functionCalls", []):
                        if scenario == "audio-cancel" and first_call:
                            input_task.cancel()
                            await asyncio.gather(input_task, return_exceptions=True)
                            input_task = asyncio.create_task(
                                stream_audio(correction_audio, 0)
                            )
                            tasks.append(input_task)
                            report["correction_sent"] = True
                        elif scenario == "cancel" and first_call:
                            await send(
                                {
                                    "realtimeInput": {
                                        "text": "Actually, cancel that request. Check order 123 instead."
                                    }
                                }
                            )
                        else:
                            tasks.append(asyncio.create_task(result(call)))
                        first_call = False
                    content = event.get("serverContent", {})
                    if content.get("interactionStatus") == "IDLE":
                        report["idle_observed"] = True
                        report["tool_observed"] = not first_call
                        break
    except Exception as error:
        report["error"] = {
            "type": type(error).__name__,
            "message": str(error).replace(key, "[REDACTED]")[:600],
        }
    finally:
        report["task_errors"] = [
            type(t.exception()).__name__
            for t in tasks
            if t.done() and not t.cancelled() and t.exception()
        ]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    return report


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", choices=["v1beta", "v1alpha"], default="v1beta")
    parser.add_argument(
        "--scenario",
        choices=["tool", "cancel", "audio", "audio-cancel"],
        default="tool",
    )
    parser.add_argument("--audio")
    parser.add_argument("--correction-audio")
    parser.add_argument("--manual-vad", action="store_true")
    parser.add_argument("--sdk-casing", action="store_true")
    parser.add_argument("--thinking", choices=["low", "medium", "high"], default="low")
    parser.add_argument("--tool-name", default="delegate_to_backend")
    args = parser.parse_args()
    key = credential()
    result = await probe(
        key,
        args.version,
        args.scenario,
        args.audio,
        args.manual_vad,
        args.sdk_casing,
        args.thinking,
        args.tool_name,
        args.correction_audio,
    )
    result["passed"] = bool(
        result.get("idle_observed")
        and result.get("tool_observed")
        and not result.get("error")
        and not result.get("task_errors")
    )
    if args.scenario in ("cancel", "audio-cancel"):
        result["passed"] = result["passed"] and any(
            e.get("toolCallCancellation") for e in result["events"]
        )
    print(json.dumps(result, indent=2).replace(key, "[REDACTED]"))
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())
