# Diagnostic comparison using google-genai; not a production dependency.
import argparse
import asyncio
import datetime
import hashlib
import importlib.metadata
import json
import time
from pathlib import Path

from gemini_protocol_pilot import credential
from google import genai
from google.genai import types


async def main(
    minimal_tool=False,
    thinking="low",
    timeout=45,
    model="gemini-3.8-live-extended-thinking",
    behavior="NON_BLOCKING",
):
    extended = model.endswith("-extended-thinking")
    if extended and behavior != "NON_BLOCKING":
        raise ValueError("Extended Thinking requires NON_BLOCKING tools")
    key = credential()
    start = time.monotonic()
    events = []
    result_transcript = []
    report = {
        "sdk": importlib.metadata.version("google-genai"),
        "model": model,
        "thinking": thinking if extended else None,
        "behavior": behavior,
        "api_version": "v1alpha",
        "timeout_seconds": timeout,
        "started_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "minimal_tool": minimal_tool,
        "events": events,
    }
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        thinking_config=types.ThinkingConfig(thinking_level=thinking.upper())
        if extended
        else None,
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        system_instruction=(
            "Use turn_on_the_lights when asked to turn on lights. This is a simulated test fixture."
            if minimal_tool
            else "Use delegate_to_backend for every order lookup. Speak only verified results."
        ),
        tools=[
            types.Tool(
                function_declarations=[
                    types.FunctionDeclaration(
                        name="turn_on_the_lights"
                        if minimal_tool
                        else "delegate_to_backend",
                        description="Simulate turning on lights."
                        if minimal_tool
                        else "Check an order.",
                        behavior=behavior,
                        parameters=None
                        if minimal_tool
                        else {
                            "type": "OBJECT",
                            "properties": {"request": {"type": "STRING"}},
                            "required": ["request"],
                        },
                    )
                ]
            )
        ],
    )
    report["config"] = config.model_dump(mode="json", exclude_none=True)
    task = None
    try:
        async with asyncio.timeout(timeout):
            async with genai.Client(
                api_key=key, http_options={"api_version": "v1alpha"}
            ).aio.live.connect(model=report["model"], config=config) as session:
                report["setup_complete"] = session.setup_complete is not None

                async def silence():
                    while True:
                        await session.send_realtime_input(
                            audio=types.Blob(
                                data=bytes(640), mime_type="audio/pcm;rate=16000"
                            )
                        )
                        await asyncio.sleep(0.02)

                task = asyncio.create_task(silence())
                await session.send_client_content(
                    turns=types.Content(
                        role="user",
                        parts=[
                            types.Part(
                                text="Turn on the lights."
                                if minimal_tool
                                else "Check order 124."
                            )
                        ],
                    ),
                    turn_complete=True,
                )
                while True:
                    async for message in session.receive():
                        data = message.model_dump(exclude_none=True)
                        content = data.get("server_content", {})
                        if report.get("tool_observed"):
                            result_transcript.append(
                                content.get("output_transcription", {}).get("text", "")
                            )
                        events.append(
                            {
                                "ms": round((time.monotonic() - start) * 1000),
                                "fields": list(data),
                                "content_fields": list(content),
                                "transcript": content.get("output_transcription"),
                                "tool_call": data.get("tool_call"),
                                "activity": data.get("interaction_status")
                                or content.get("interaction_status"),
                                "usage": data.get("usage_metadata"),
                            }
                        )
                        if message.tool_call:
                            report["tool_observed"] = True
                            for call in message.tool_call.function_calls:
                                expected_name = (
                                    "turn_on_the_lights"
                                    if minimal_tool
                                    else "delegate_to_backend"
                                )
                                if not call.id or call.name != expected_name:
                                    raise ValueError(
                                        "Unexpected or uncorrelated tool call"
                                    )
                                await session.send_tool_response(
                                    function_responses=[
                                        types.FunctionResponse(
                                            id=call.id,
                                            name=call.name,
                                            response={
                                                "result": "Simulated lights are on."
                                                if minimal_tool
                                                else "Order 124 is arriving Friday."
                                            },
                                        )
                                    ]
                                )
                                events.append(
                                    {
                                        "ms": round((time.monotonic() - start) * 1000),
                                        "response_sent": {
                                            "id": call.id,
                                            "name": call.name,
                                        },
                                    }
                                )
                        activity = data.get("interaction_status") or content.get(
                            "interaction_status"
                        )
                        if activity == "IDLE":
                            report["idle_observed"] = True
                            report["completion_signal"] = "interaction_status:IDLE"
                            return report
                        if (
                            not extended
                            and activity in (None, "INTERACTION_STATUS_UNSPECIFIED")
                            and content.get("turn_complete")
                            and report.get("tool_observed")
                            and any(result_transcript)
                        ):
                            report["idle_observed"] = True
                            report["completion_signal"] = "post_tool_turn_complete"
                            return report
    except Exception as e:  # noqa: BLE001 -- redact failures from the external SDK
        report["error"] = {
            "type": type(e).__name__,
            "message": str(e).replace(key, "[REDACTED]")[:400],
        }
    finally:
        if task:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        report["protocol_completed"] = bool(
            report.get("tool_observed")
            and report.get("idle_observed")
            and not report.get("error")
        )
        report["result_transcript"] = "".join(result_transcript)
        report["elapsed_ms"] = round((time.monotonic() - start) * 1000)
        result_text = report["result_transcript"].lower()
        report["passed"] = bool(
            report["protocol_completed"]
            and "system error" not in result_text
            and (
                ("lights" in result_text and "on" in result_text)
                if minimal_tool
                else ("124" in result_text and "friday" in result_text)
            )
        )
        print(json.dumps(report, indent=2).replace(key, "[REDACTED]"))
        if not report["passed"]:
            raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimal-tool", action="store_true")
    parser.add_argument("--thinking", choices=["low", "medium", "high"], default="low")
    parser.add_argument("--timeout", type=int, choices=range(1, 121), default=45)
    parser.add_argument(
        "--model",
        choices=["gemini-3.8-live", "gemini-3.8-live-extended-thinking"],
        default="gemini-3.8-live-extended-thinking",
    )
    parser.add_argument(
        "--behavior", choices=["NON_BLOCKING", "BLOCKING"], default="NON_BLOCKING"
    )
    args = parser.parse_args()
    if args.model.endswith("-extended-thinking") and args.behavior != "NON_BLOCKING":
        parser.error("Extended Thinking requires --behavior NON_BLOCKING")
    asyncio.run(
        main(args.minimal_tool, args.thinking, args.timeout, args.model, args.behavior)
    )
