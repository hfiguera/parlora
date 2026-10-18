"""Offline regressions for model-specific setup and honest pilot completion."""

import contextlib
import io
import json
import unittest
from unittest.mock import patch

import gemini_sdk_pilot as pilot
from google.genai import types


class Session:
    setup_complete = object()

    def __init__(self, messages):
        self.messages = messages
        self.responses = []

    async def send_realtime_input(self, **_kwargs):
        pass

    async def send_client_content(self, **_kwargs):
        pass

    async def send_tool_response(self, **kwargs):
        self.responses.extend(kwargs["function_responses"])

    async def receive(self):
        for message in self.messages:
            yield types.LiveServerMessage.model_validate(message)
        # The pilot must terminate on the expected completion, not spin forever.
        raise AssertionError("Pilot missed final completion")


class PilotTest(unittest.IsolatedAsyncioTestCase):
    async def run_probe(self, model, messages, expect_pass=True):
        session = Session(messages)
        configs = []

        class Client:
            def __init__(self, **_kwargs):
                self.aio = self
                self.live = self

            @contextlib.asynccontextmanager
            async def connect(self, **kwargs):
                configs.append(kwargs["config"])
                yield session

        output = io.StringIO()
        with (
            patch.object(pilot, "credential", return_value="offline-test-key"),
            patch.object(pilot.genai, "Client", Client),
            contextlib.redirect_stdout(output),
        ):
            if expect_pass:
                await pilot.main(True, "high", 1, model)
            else:
                with self.assertRaises(SystemExit):
                    await pilot.main(True, "high", 1, model)
        return json.loads(output.getvalue()), configs[0], session

    @staticmethod
    def call():
        return {
            "tool_call": {
                "function_calls": [
                    {"id": "call-1", "name": "turn_on_the_lights", "args": {}},
                ]
            }
        }

    async def test_standard_omits_thinking_and_accepts_final_turn_complete(self):
        report, config, session = await self.run_probe(
            "gemini-3.8-live",
            [
                self.call(),
                {
                    "server_content": {
                        "output_transcription": {"text": "The lights are on."},
                        "turn_complete": True,
                    }
                },
            ],
        )
        self.assertNotIn("thinking_config", config.model_dump(exclude_none=True))
        self.assertTrue(report["passed"])
        self.assertEqual(report["completion_signal"], "post_tool_turn_complete")
        self.assertEqual(session.responses[0].id, "call-1")
        self.assertEqual(session.responses[0].name, "turn_on_the_lights")

    async def test_extended_keeps_receiving_after_filler_and_until_idle(self):
        report, config, _ = await self.run_probe(
            "gemini-3.8-live-extended-thinking",
            [
                {
                    "server_content": {
                        "output_transcription": {"text": "Let me check."},
                        "turn_complete": True,
                        "interaction_status": "IN_PROGRESS",
                    }
                },
                self.call(),
                {
                    "server_content": {
                        "output_transcription": {"text": "The lights are on."},
                        "turn_complete": True,
                        "interaction_status": "IN_PROGRESS",
                    }
                },
                {"server_content": {"interaction_status": "IDLE"}},
            ],
        )
        self.assertEqual(config.thinking_config.thinking_level, "HIGH")
        self.assertTrue(report["passed"])
        self.assertEqual(report["completion_signal"], "interaction_status:IDLE")

    async def test_tool_and_idle_with_system_error_is_not_task_success(self):
        report, _, _ = await self.run_probe(
            "gemini-3.8-live-extended-thinking",
            [
                self.call(),
                {
                    "server_content": {
                        "output_transcription": {"text": "A system error occurred."},
                        "turn_complete": True,
                        "interaction_status": "IDLE",
                    }
                },
            ],
            expect_pass=False,
        )
        self.assertTrue(report["protocol_completed"])
        self.assertFalse(report["passed"])

    async def test_blocking_extended_rejected_before_credential_access(self):
        with patch.object(pilot, "credential") as credential:
            with self.assertRaises(ValueError):
                await pilot.main(
                    model="gemini-3.8-live-extended-thinking", behavior="BLOCKING"
                )
            credential.assert_not_called()


if __name__ == "__main__":
    unittest.main()
