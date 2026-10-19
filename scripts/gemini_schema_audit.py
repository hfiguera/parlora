"""Compare production JSON with the SDK's actual sends, offline with a dummy key."""

import asyncio
import contextlib
import datetime
import hashlib
import importlib.metadata
import json
import os
import subprocess
from pathlib import Path
from unittest.mock import patch

from google import genai
from google.genai import types


async def main():
    source = Path("lib/parlora/providers/gemini/protocol.ex")
    code = """
    {:ok, %{setup: setup}} = Parlora.Providers.Gemini.Protocol.start(
      [api_key: "offline-schema-check"], %Parlora.AudioFormat{})
    response = Parlora.Providers.Gemini.Protocol.tool_result("audit-call", %{result: "Order 124 is arriving Friday."})
    IO.puts("SCHEMA_JSON:" <> JSON.encode!(%{setup: setup, response: response}))
    """
    result = await asyncio.to_thread(
        subprocess.run,
        ["mix", "run", "-e", code],
        env={**os.environ, "MIX_ENV": "test"},
        capture_output=True,
        text=True,
        check=True,
    )
    production = json.loads(
        next(
            line.removeprefix("SCHEMA_JSON:")
            for line in result.stdout.splitlines()
            if line.startswith("SCHEMA_JSON:")
        )
    )
    sent = []

    class Socket:
        async def send(self, message):
            sent.append(json.loads(message))

        async def recv(self, **_kwargs):
            return '{"setupComplete": {}}'

    @contextlib.asynccontextmanager
    async def offline_socket(*_args, **_kwargs):
        yield Socket()

    setup = production["setup"]
    config = types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        tools=[types.Tool.model_validate(tool) for tool in setup["tools"]],
    )
    # Patch the connection itself: the SDK serializes normally but cannot access the network.
    with patch("google.genai.live.ws_connect", offline_socket):
        async with genai.Client(api_key="offline-schema-check").aio.live.connect(
            model=setup["model"], config=config
        ) as session:
            await session.send_tool_response(
                function_responses=[
                    types.FunctionResponse(
                        id="audit-call",
                        name="delegate_to_backend",
                        scheduling="WHEN_IDLE",
                        response={"result": "Order 124 is arriving Friday."},
                    )
                ]
            )
    checks = {
        "tools_identical": setup["tools"] == sent[0]["setup"]["tools"],
        "thinking_omitted": "thinkingConfig" not in setup["generationConfig"]
        and "thinkingConfig" not in sent[0]["setup"]["generationConfig"],
        "response_body_identical": production["response"]["toolResponse"]
        == sent[1]["tool_response"],
    }
    report = {
        "created_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "sdk": importlib.metadata.version("google-genai"),
        "protocol_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "network": "disabled by mocked WebSocket; dummy credential only",
        "production_tools": setup["tools"],
        "production_model": setup["model"],
        "production_response": production["response"],
        "sdk_messages": sent,
        "checks": checks,
        "note": "SDK sends tool_response; Parlora uses protobuf JSON camelCase toolResponse. Neither sends a thinking configuration. Response bodies are compared without changing their keys.",
        "passed": all(checks.values()),
    }
    print(json.dumps(report, indent=2))
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    asyncio.run(main())
