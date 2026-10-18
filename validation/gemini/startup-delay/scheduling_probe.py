"""Bounded direct-wire scheduling comparison with synthetic speech and quiet noise.

Uses the exported application's setup and private Keychain credential helper.
No microphone recording, credentials, audio bytes or resume handles are persisted.
"""
import asyncio
import base64
import hashlib
import json
import random
import struct
import sys
import time
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from gemini_protocol_pilot import credential
from websockets.asyncio.client import connect


async def probe(setup, pcm, scheduling, will_continue):
    started = time.monotonic()
    events = []
    report = {"scheduling": scheduling, "will_continue": will_continue, "events": events}
    stream = None
    key = credential()
    speech_at = None
    result_at = None
    first_reply = None
    seen = set()
    rng = random.Random(42)

    def record(kind, **fields):
        events.append({"ms": round((time.monotonic() - started) * 1000), "kind": kind, **fields})

    try:
        async with asyncio.timeout(75):
            async with connect(
                "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                additional_headers={"x-goog-api-key": key}, open_timeout=10, max_size=2**20,
            ) as ws:
                async def send(value):
                    await ws.send(json.dumps(value))

                async def audio():
                    position = 0
                    clip_started = False
                    clip_ended = False
                    deadline = time.monotonic()
                    while True:
                        noise = [round(rng.gauss(0, 20)) for _ in range(320)]
                        if speech_at is not None and time.monotonic() >= speech_at and position < len(pcm):
                            if not clip_started:
                                record("clip_start")
                                clip_started = True
                            chunk = pcm[position:position + 640].ljust(640, b"\0")
                            position += 640
                            samples = struct.unpack("<320h", chunk)
                            noise = [max(-32768, min(32767, a + b)) for a, b in zip(samples, noise)]
                        elif clip_started and not clip_ended:
                            record("clip_end")
                            clip_ended = True
                        data = struct.pack("<320h", *noise)
                        await send({"realtimeInput": {"audio": {
                            "mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(data).decode()
                        }}})
                        deadline += .02
                        await asyncio.sleep(max(0, deadline - time.monotonic()))

                await send({"setup": setup})
                async for raw in ws:
                    message = json.loads(raw)
                    if "setupComplete" in message:
                        record("ready")
                        stream = asyncio.create_task(audio())
                        await send({"clientContent": {"turns": [{"role": "user", "parts": [{
                            "text": "Application update: Speak English. Greet the caller immediately without waiting for them to speak: Hi, I can help check an order. Then pause and listen."
                        }]}], "turnComplete": True}})
                    content = message.get("serverContent", {})
                    for field in ("inputTranscription", "outputTranscription"):
                        if field in content:
                            record(field, text=content[field].get("text", ""))
                    if content.get("turnComplete"):
                        record("turn_complete")
                        if speech_at is None:
                            speech_at = time.monotonic() + .5
                        elif first_reply is not None:
                            report["status"] = "answered"
                            break
                    if content.get("interrupted"):
                        record("interrupted")
                    if result_at is not None and first_reply is None and content.get("modelTurn"):
                        first_reply = time.monotonic()
                        report["result_to_first_reply_ms"] = round((first_reply - result_at) * 1000)
                    for call in message.get("toolCall", {}).get("functionCalls", []):
                        record("call", id=call.get("id"), name=call.get("name"))
                        if call.get("id") in seen:
                            continue
                        seen.add(call.get("id"))
                        assert call.get("name") == "delegate_to_backend"
                        # Match the human call's interpretation + fast lookup interval.
                        await asyncio.sleep(.474)
                        response = {"id": call["id"], "name": call["name"],
                                    "response": {"result": "Order 124 is out for delivery. Tracking: DEMO-124. No delivery date is provided."},
                                    "scheduling": scheduling}
                        if will_continue is not None:
                            response["willContinue"] = will_continue
                        await send({"toolResponse": {"functionResponses": [response]}})
                        result_at = time.monotonic()
                        record("result_sent", id=call["id"])
                    if "error" in message:
                        record("error", code=message["error"].get("code"))
    except TimeoutError:
        report["status"] = "timeout"
    except Exception as error:
        # Exception text may contain request details; retain only the class.
        report["status"] = "error"
        report["error_type"] = type(error).__name__
    finally:
        if stream:
            stream.cancel()
            await asyncio.gather(stream, return_exceptions=True)
    return report


async def main():
    setup_path, audio_path, output = map(Path, sys.argv[1:])
    setup = json.loads(setup_path.read_text())
    with wave.open(str(audio_path), "rb") as source:
        assert (source.getframerate(), source.getnchannels(), source.getsampwidth()) == (16000, 1, 2)
        pcm = source.readframes(source.getnframes())
    report = {"model": setup["model"], "setup": setup, "noise_rms_pcm16": 20,
              "audio_sha256": hashlib.sha256(pcm).hexdigest(), "cases": []}
    for mode, continued in [("WHEN_IDLE", None), ("WHEN_IDLE", False), ("INTERRUPT", None)]:
        result = await probe(setup, pcm, mode, continued)
        report["cases"].append(result)
        output.write_text(json.dumps(report, indent=2))
        print(mode, continued, result.get("status"), result.get("result_to_first_reply_ms"), flush=True)


if __name__ == "__main__":
    asyncio.run(main())
