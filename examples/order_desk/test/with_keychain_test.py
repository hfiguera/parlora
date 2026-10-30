"""Exercise documented launch commands without accounts, Keychain, or listeners."""
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


EXAMPLE = Path(__file__).resolve().parents[1]
WRAPPER = EXAMPLE / "scripts/with_keychain.py"


class KeychainLauncherTest(unittest.TestCase):
    def run_wrapper(self, settings, keychain_status=0):
        requested = []

        def keychain(args, **_kwargs):
            requested.append(args)
            return subprocess.CompletedProcess(args, keychain_status, stdout=b"dummy-secret\n")

        with patch.dict(os.environ, settings, clear=True), \
                patch.object(sys, "argv", [str(WRAPPER), "mix", "run"]), \
                patch("subprocess.run", side_effect=keychain), \
                patch("os.execvpe") as execute:
            runpy.run_path(str(WRAPPER), run_name="__main__")
        return requested, execute

    def base(self):
        return {
            "OPENAI_API_KEY": "dummy-openai",
            "TYPESAFE_API_KEY": "dummy-typesafe",
            "ORDER_DESK_TYPESAFE": "1",
            "ORDER_DESK_TWILIO": "incoming",
        }

    def test_phonic_uses_its_existing_keychain_service(self):
        requested, execute = self.run_wrapper({"PARLORA_PROVIDER": "phonic"})
        self.assertEqual(requested, [[
            "/usr/bin/security", "find-generic-password", "-s",
            "parlora-phonic-development", "-w",
        ]])
        self.assertEqual(execute.call_args.args[2]["PHONIC_API_KEY"], "dummy-secret")
        self.assertNotIn("OPENAI_API_KEY", execute.call_args.args[2])

    def test_explicit_phonic_key_bypasses_keychain(self):
        requested, execute = self.run_wrapper({
            "PARLORA_PROVIDER": "phonic", "PHONIC_API_KEY": "dummy-phonic",
        })
        self.assertEqual(requested, [])
        self.assertEqual(execute.call_args.args[2]["PHONIC_API_KEY"], "dummy-phonic")

    def test_missing_phonic_key_stops_before_launch(self):
        with self.assertRaisesRegex(SystemExit, "selected provider's Keychain credential"):
            self.run_wrapper({"PARLORA_PROVIDER": "phonic"}, keychain_status=1)

    def test_incoming_calls_use_only_the_documented_credentials(self):
        settings = self.base() | {
            "TWILIO_ACCOUNT_SID": "dummy-account",
            "TWILIO_AUTH_TOKEN": "dummy-token",
            "TWILIO_PHONE_NUMBER": "+15555550123",
        }
        requested, execute = self.run_wrapper(settings)
        self.assertEqual(requested, [])
        execute.assert_called_once()
        child = execute.call_args.args[2]
        self.assertEqual(child["TWILIO_AUTH_TOKEN"], "dummy-token")
        self.assertNotIn("TWILIO_API_KEY_SID", child)
        self.assertNotIn("TWILIO_API_KEY_SECRET", child)
        self.assertNotIn("TWILIO_PHONE_NUMBER_SID", child)

    def test_incoming_keychain_fallback_does_not_require_caller_or_routing_keys(self):
        requested, execute = self.run_wrapper(self.base())
        accounts = {args[args.index("-a") + 1] for args in requested}
        self.assertEqual(accounts, {"account_sid", "auth_token", "phone_number_e164"})
        execute.assert_called_once()

    def test_existing_full_mode_preserves_caller_and_routing_credentials(self):
        requested, execute = self.run_wrapper(self.base() | {"ORDER_DESK_TWILIO": "1"})
        accounts = {args[args.index("-a") + 1] for args in requested}
        self.assertEqual(accounts, {
            "account_sid", "auth_token", "phone_number_e164", "phone_number_sid",
            "voice_sdk_api_key_sid", "voice_sdk_api_key_secret",
        })
        child = execute.call_args.args[2]
        self.assertIn("TWILIO_API_KEY_SECRET", child)
        self.assertIn("TWILIO_PHONE_NUMBER_SID", child)

    def test_missing_required_credential_fails_without_running_the_application(self):
        with patch.dict(os.environ, self.base(), clear=True), \
                patch.object(sys, "argv", [str(WRAPPER), "mix", "run"]), \
                patch("subprocess.run", return_value=subprocess.CompletedProcess([], 1, stdout=b"")), \
                patch("os.execvpe") as execute:
            with self.assertRaisesRegex(SystemExit, "required Twilio Keychain credential"):
                runpy.run_path(str(WRAPPER), run_name="__main__")
            execute.assert_not_called()

    def test_documented_phone_commands_reach_the_application_on_both_platforms(self):
        readme = (EXAMPLE / "README.md").read_text()
        for platform in ["Linux", "Darwin"]:
            for carrier, entrypoint in [("twilio", "TwilioServer"), ("telnyx", "TelnyxServer")]:
                with self.subTest(platform=platform, carrier=carrier), tempfile.TemporaryDirectory() as directory:
                    binary = Path(directory)
                    (binary / "uname").write_text(f"#!/bin/sh\necho {platform}\n")
                    output = '''import json, os, sys
print(json.dumps({"args": sys.argv[1:], "database": os.environ["ORDER_DESK_DATABASE"], "twilio_mode": os.environ.get("ORDER_DESK_TWILIO")}))
'''
                    for command in ["mix", "python3"]:
                        (binary / command).write_text(f"#!{sys.executable}\n" + output)
                    for command in binary.iterdir():
                        command.chmod(0o755)
                    pattern = rf"(?m)^{carrier.upper()}_PUBLIC_URL=[^\n]* \\\nORDER_DESK_DATABASE=[^\n]*scripts/{carrier}\.sh"
                    command = re.search(pattern, readme)
                    self.assertIsNotNone(command, "Keep a complete executable phone launch command in README")
                    result = subprocess.run(
                        ["/bin/sh", "-c", command.group()], cwd=EXAMPLE,
                        env={"PATH": f"{binary}{os.pathsep}{os.defpath}"},
                        capture_output=True, text=True, timeout=5, check=True,
                    )
                    child = json.loads(result.stdout)
                    self.assertTrue(Path(child["database"]).is_absolute())
                    self.assertIn(f"OrderDesk.{entrypoint}.run()", child["args"][-1])
                    if carrier == "twilio":
                        self.assertEqual(child["twilio_mode"], "incoming")


if __name__ == "__main__":
    unittest.main()
