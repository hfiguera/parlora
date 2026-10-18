"""Bounded live idle-resumption probe. Handles and credentials remain in memory."""

import argparse
import asyncio
import base64
import json
import time

from gemini_protocol_pilot import credential
from websockets.asyncio.client import connect


async def main(reconnect_delay=0):
    key = credential()
    started = time.monotonic()
    report = {
        "model": "gemini-3.8-live-extended-thinking",
        "reconnect_delay_seconds": reconnect_delay,
        "phases": [],
    }
    handle = None
    try:
        async with asyncio.timeout(50):
            for phase in ("initial", "resumed"):
                row = {"phase": phase, "captions": [], "audio_bytes": 0}
                report["phases"].append(row)
                async with connect(
                    "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                    additional_headers={"x-goog-api-key": key},
                    max_size=2**20,
                ) as ws:

                    async def send(data):
                        await ws.send(json.dumps(data))

                    async def silence():
                        while True:
                            await send(
                                {
                                    "realtimeInput": {
                                        "audio": {
                                            "mimeType": "audio/pcm;rate=16000",
                                            "data": base64.b64encode(
                                                bytes(640)
                                            ).decode(),
                                        }
                                    }
                                }
                            )
                            await asyncio.sleep(0.02)

                    await send(
                        {
                            "setup": {
                                "model": "models/" + report["model"],
                                "generationConfig": {
                                    "responseModalities": ["AUDIO"],
                                    "thinkingConfig": {"thinkingLevel": "LOW"},
                                },
                                "outputAudioTranscription": {},
                                "sessionResumption": {"handle": handle}
                                if handle
                                else {},
                                "contextWindowCompression": {"slidingWindow": {}},
                            }
                        }
                    )
                    sender = None
                    resumable = False
                    idle = False
                    try:
                        async for raw in ws:
                            event = json.loads(raw)
                            if "setupComplete" in event:
                                row["setup_ok"] = True
                                sender = asyncio.create_task(silence())
                                prompt = (
                                    "The reference number is 124. Remember it and say okay."
                                    if phase == "initial"
                                    else "What is the reference number?"
                                )
                                await send(
                                    {
                                        "clientContent": {
                                            "turns": [
                                                {
                                                    "role": "user",
                                                    "parts": [{"text": prompt}],
                                                }
                                            ],
                                            "turnComplete": True,
                                        }
                                    }
                                )
                            update = event.get("sessionResumptionUpdate")
                            if update:
                                resumable = update.get("resumable") is True and bool(
                                    update.get("newHandle")
                                )
                                handle = update.get("newHandle") if resumable else None
                            content = event.get("serverContent", {})
                            if content.get("outputTranscription"):
                                row["captions"].append(
                                    content["outputTranscription"]["text"]
                                )
                            row["audio_bytes"] += sum(
                                len(base64.b64decode(p["inlineData"]["data"]))
                                for p in content.get("modelTurn", {}).get("parts", [])
                                if "inlineData" in p
                            )
                            idle = content.get("interactionStatus") == "IDLE" or idle
                            if idle and (resumable or phase == "resumed"):
                                row["idle"] = True
                                row["resumable"] = resumable
                                break
                    finally:
                        if sender:
                            sender.cancel()
                            await asyncio.gather(sender, return_exceptions=True)
                if phase == "initial":
                    if not handle:
                        raise RuntimeError("No safe idle resumption handle")
                    await asyncio.sleep(reconnect_delay)
        report["passed"] = report["phases"][-1].get("idle") and "124" in "".join(
            report["phases"][-1]["captions"]
        )
    except Exception as error:  # noqa: BLE001 -- retain sanitized probe failures
        report["passed"] = False
        report["error"] = {"type": type(error).__name__}
        close = getattr(error, "rcvd", None)
        if close:
            reason = close.reason.replace(key, "[REDACTED]")
            if handle:
                reason = reason.replace(handle, "[REDACTED_HANDLE]")
            report["error"].update(code=close.code, reason=reason[:600])
    report["elapsed_ms"] = round((time.monotonic() - started) * 1000)
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--reconnect-delay", type=float, choices=[0, 2], default=0)
    asyncio.run(main(parser.parse_args().reconnect_delay))
