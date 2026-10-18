"""Bounded raw-API turn/clarification probe; no business actions or human recordings.

Synthetic speech stays in the caller-supplied temporary directory. Credentials
are read privately, used in the authentication header, and never persisted.
Run with the probe venv: turn_probe.py OUTPUT_DIR MODE [REPEATS]
Use goodbye_auto, goodbye_manual, goodbye_head, or goodbye_minimal for isolated
single-utterance trials. paired alternates HEAD/current order for each pair.
Exploratory multi-turn modes: current, no_updates, realtime_updates,
realtime_all, manual, manual_no_updates, minimal. Their stage labels alone do
not correlate an overlapping reply to a request; inspect the complete events.
"""
import asyncio
import base64
import copy
import hashlib
import json
import random
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from gemini_protocol_pilot import credential
from websockets.asyncio.client import connect

UTTERANCES = [
    "Sure, let's check the order one hundred twenty three.",
    "Sorry, I mean one hundred twenty four.",
    "Do you know what items are there?",
    "Right, let's change the delivery instructions.",
    "Leave it with my neighbor.",
    "Okay, thank you. Bye.",
]
RESULTS = [
    "Order 123 is shipped and expected Friday.",
    "Order 124 is out for delivery.",
    "Order 124 contains one desk lamp.",
    "No draft is ready yet. Ask what the new delivery instructions should be for order 124.",
    'A draft for order 124 has been created with the instruction "Leave it with my neighbor." Ask the caller to review and confirm on screen.',
    "No backend work is needed. Say goodbye briefly.",
]


def clips(directory):
    result = []
    for i, text in enumerate(UTTERANCES):
        wav = directory / f"speech-{i}.wav"
        if not wav.exists():
            aiff = directory / f"speech-{i}.aiff"
            subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(aiff), text], check=True)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
        with wave.open(str(wav), "rb") as stream:
            assert (stream.getframerate(), stream.getnchannels(), stream.getsampwidth()) == (16000, 1, 2)
            result.append(stream.readframes(stream.getnframes()))
    return result


async def probe(setup, speech, mode, output):
    setup = copy.deepcopy(setup)
    manual = mode in ["manual", "manual_no_updates", "goodbye_manual"]
    activity_open = False
    if manual:
        setup["realtimeInputConfig"]["automaticActivityDetection"] = {"disabled": True}
    if mode in ["minimal", "goodbye_minimal"]:
        setup["systemInstruction"] = {"parts": [{"text": "You are a helpful English voice assistant. Respond briefly to each request and say goodbye when the caller says goodbye. Use delegate_to_backend for order facts or changes. Ask for missing details."}]}
    if mode == "goodbye_minimal":
        setup["systemInstruction"] = {"parts": [{"text": "You are a helpful English voice assistant. Respond briefly to each request and say goodbye when the caller says goodbye."}]}
        setup.pop("tools", None)
    report = {"mode": mode, "setup": setup, "events": [], "turns": [], "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "transport": {"compression": None, "automatic_ping": False, "diagnostic_ping_seconds": 5}, "synthetic_audio_hashes": [hashlib.sha256(x).hexdigest() for x in speech]}
    started = time.monotonic()
    stage = -1
    active_pcm = b""
    position = 0
    ended = asyncio.Event()
    turn_done = asyncio.Event()
    ready = asyncio.Event()
    seen_calls = set()
    tasks = []
    rng = random.Random(42)
    stream_stats = {"frames": 0, "max_gap_ms": 0, "last_send_ms": None}

    def now():
        return round((time.monotonic() - started) * 1000)

    def record(kind, **fields):
        report["events"].append({"ms": now(), "stage": stage, "kind": kind, **fields})

    try:
        async with asyncio.timeout(300):
            async with connect("wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent", additional_headers={"x-goog-api-key": credential()}, open_timeout=10, max_size=2**22, ping_interval=None, compression=None) as ws:
                async def send(value):
                    await ws.send(json.dumps(value))

                async def text(value, kind="clientContent"):
                    if mode == "realtime_all": kind = "realtimeInput"
                    record("text_sent", transport=kind, text=value)
                    if kind == "realtimeInput":
                        await send({"realtimeInput": {"text": "Application update: " + value}})
                    else:
                        await send({"clientContent": {"turns": [{"role": "user", "parts": [{"text": "Application update: " + value}]}], "turnComplete": True}})

                async def stream():
                    nonlocal position
                    deadline = time.monotonic()
                    while True:
                        noise = [round(rng.gauss(0, 20)) for _ in range(320)]
                        if position < len(active_pcm):
                            chunk = active_pcm[position:position + 640].ljust(640, b"\0")
                            position += 640
                            noise = [max(-32768, min(32767, a + b)) for a, b in zip(struct.unpack("<320h", chunk), noise)]
                        elif active_pcm and not ended.is_set():
                            record("clip_end")
                            ended.set()
                        if mode != "goodbye_manual" or activity_open:
                            await send({"realtimeInput": {"audio": {"mimeType": "audio/pcm;rate=16000", "data": base64.b64encode(struct.pack("<320h", *noise)).decode()}}})
                            sent = now()
                            if stream_stats["last_send_ms"] is not None:
                                stream_stats["max_gap_ms"] = max(stream_stats["max_gap_ms"], sent - stream_stats["last_send_ms"])
                            stream_stats["last_send_ms"] = sent
                            stream_stats["frames"] += 1
                        deadline += .02
                        await asyncio.sleep(max(0, deadline - time.monotonic()))

                async def respond(call, index):
                    await asyncio.sleep(.5)
                    await send({"toolResponse": {"functionResponses": [{"id": call["id"], "name": call["name"], "response": {"result": RESULTS[max(0, index)]}, "scheduling": "WHEN_IDLE"}]}})
                    record("tool_result_sent", id=call["id"], for_stage=index)

                async def heartbeat():
                    while True:
                        await asyncio.sleep(5)
                        ping_start = now()
                        record("send_health", **stream_stats)
                        record("ping_sent")
                        waiter = await ws.ping()
                        try:
                            await asyncio.wait_for(asyncio.shield(waiter), 10)
                            record("pong", round_trip_ms=now() - ping_start)
                        except TimeoutError:
                            record("pong_timeout")
                        output.write_text(json.dumps(report, indent=2))

                async def receive():
                    async for raw in ws:
                        m = json.loads(raw)
                        if "setupComplete" in m:
                            record("ready")
                            ready.set()
                        c = m.get("serverContent", {})
                        for field in ["inputTranscription", "outputTranscription"]:
                            if field in c:
                                record(field, text=c[field].get("text", ""), finished=c[field].get("finished"))
                        if any(len(p.get("inlineData", {}).get("data", "")) > 4 for p in c.get("modelTurn", {}).get("parts", [])):
                            if not report["events"] or not any(e["kind"] == "first_audio" and e["stage"] == stage for e in report["events"]):
                                record("first_audio")
                        for field in ["turnComplete", "generationComplete", "interrupted"]:
                            if c.get(field): record(field)
                        if c.get("turnComplete") and (stage == -1 or any(e["kind"] == "first_audio" and e["stage"] == stage for e in report["events"])):
                            turn_done.set()
                        for call in m.get("toolCall", {}).get("functionCalls", []):
                            record("tool_call", id=call.get("id"), name=call.get("name"))
                            if call["id"] not in seen_calls:
                                seen_calls.add(call["id"])
                                tasks.append(asyncio.create_task(respond(call, stage)))
                        if "toolCallCancellation" in m:
                            record("tool_cancelled", ids=m["toolCallCancellation"].get("ids", []))
                        if "error" in m:
                            record("error", code=m["error"].get("code"))
                        if "usageMetadata" in m:
                            record("usage", usage=m["usageMetadata"])

                async def supervised_receive():
                    try:
                        await receive()
                        record("receive_ended")
                    except asyncio.CancelledError:
                        raise
                    except Exception as error:
                        record("receive_failed", error_type=type(error).__name__, close_code=ws.close_code)
                        raise

                await send({"setup": setup})
                tasks.append(asyncio.create_task(supervised_receive()))
                await asyncio.wait_for(ready.wait(), 15)
                tasks.append(asyncio.create_task(stream()))
                tasks.append(asyncio.create_task(heartbeat()))
                await text("Greet the caller immediately: Hi, I can help check an order. Then pause and listen.")
                await asyncio.wait_for(turn_done.wait(), 20)
                for index, pcm in enumerate(speech):
                    if mode.startswith("goodbye_") and index != 5: continue
                    await asyncio.sleep(.8)
                    stage = index
                    turn_done.clear()
                    ended.clear()
                    position = 0
                    if manual:
                        await send({"realtimeInput": {"activityStart": {}}})
                        record("activityStart")
                        activity_open = True
                    record("clip_start", text=UTTERANCES[index])
                    active_pcm = pcm
                    await ended.wait()
                    end_ms = now()
                    if manual:
                        await asyncio.sleep(.7)
                        await send({"realtimeInput": {"activityEnd": {}}})
                        record("activityEnd")
                        activity_open = False
                    if index == 3 and mode in ["current", "realtime_updates", "realtime_all", "manual"]:
                        await asyncio.sleep(3)
                        await text("No draft is ready yet. What should the delivery instructions for order 124 say?", "realtimeInput" if mode == "realtime_updates" else "clientContent")
                        turn_done.clear()
                    try:
                        await asyncio.wait_for(turn_done.wait(), 40)
                        outcome = "answered"
                    except TimeoutError:
                        outcome = "timeout"
                    audio = [e["ms"] for e in report["events"] if e["stage"] == index and e["kind"] == "first_audio"]
                    transcripts = [e["ms"] for e in report["events"] if e["stage"] == index and e["kind"] == "inputTranscription"]
                    row = {"stage": index, "outcome": outcome, "clip_end_ms": end_ms, "end_to_audio_ms": audio[0] - end_ms if audio else None, "caption_to_audio_ms": audio[0] - transcripts[0] if audio and transcripts else None}
                    report["turns"].append(row)
                    output.write_text(json.dumps(report, indent=2))
                    print(mode, json.dumps(row), flush=True)
                    if outcome == "timeout": break
                    if index == 4:
                        stage = -2
                        turn_done.clear()
                        await text('Browser confirmed: delivery instructions for order 124 have been saved as "Leave it with my neighbor." Briefly announce the save.')
                        try:
                            await asyncio.wait_for(turn_done.wait(), 20)
                        except TimeoutError:
                            record("save_announcement_timeout")
                report["status"] = "finished"
    except Exception as error:
        report["status"] = "error"
        report["error_type"] = type(error).__name__
    finally:
        for task in tasks: task.cancel()
        outcomes = await asyncio.gather(*tasks, return_exceptions=True)
        report["background_task_errors"] = [type(x).__name__ for x in outcomes if isinstance(x, Exception)]
        if report["background_task_errors"]:
            report["status"] = "background_error"
        report["final_send_health"] = dict(stream_stats)
        output.write_text(json.dumps(report, indent=2))
    return report


async def main():
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    mode = sys.argv[2]
    assert mode in ["current", "no_updates", "realtime_updates", "realtime_all", "manual", "manual_no_updates", "minimal", "goodbye_auto", "goodbye_manual", "goodbye_head", "goodbye_minimal", "paired"]
    repeats = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    assert 1 <= repeats <= 8, "A batch is bounded to eight sessions or pairs."
    if mode == "paired":
        speech = clips(directory)
        for i in range(repeats):
            order = ["head", "working"] if i % 2 == 0 else ["working", "head"]
            for revision in order:
                setup = json.loads((Path(__file__).parent / f"initial-contract-{revision}.json").read_text())["setup"]
                await probe(setup, speech, "goodbye_head" if revision == "head" else "goodbye_auto", directory / f"paired-{i}-{revision}.json")
        return
    setup_file = "initial-contract-head.json" if mode == "goodbye_head" else "initial-contract-working.json"
    setup = json.loads((Path(__file__).parent / setup_file).read_text())["setup"]
    speech = clips(directory)
    for i in range(repeats):
        await probe(setup, speech, mode, directory / f"{mode}-{i}.json")


if __name__ == "__main__":
    asyncio.run(main())
