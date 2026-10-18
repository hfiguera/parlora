#!/usr/bin/env python3
"""Run development tooling with the existing Keychain secret in its environment."""
import os
import subprocess
import sys

if len(sys.argv) < 2:
    sys.exit("Usage: python3 scripts/with_keychain.py COMMAND [ARGS...]")
environment = os.environ.copy()
backend = environment.get("PARLORA_BACKEND", "jido")
backend_variable = {"sagents": "SAGENTS_API_KEY", "legion": "LEGION_API_KEY"}.get(backend)
if backend_variable and not environment.get(backend_variable):
    backend_key = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-l", "keel-openai-development", "-w"],
        capture_output=True, check=False,
    )
    if backend_key.returncode or not backend_key.stdout.strip():
        sys.exit("Could not retrieve the agent backend OpenAI Keychain credential")
    environment[backend_variable] = backend_key.stdout.decode().strip()
provider = environment.get("PARLORA_PROVIDER", "openai")
credentials = {
    "openai": ("OPENAI_API_KEY", "-l", "keel-openai-development"),
    "gemini": ("GEMINI_API_KEY", "-s", "parlora-gemini-development"),
    "grok": ("XAI_API_KEY", "-s", "parlora-grok-development"),
}
if provider not in credentials:
    sys.exit("PARLORA_PROVIDER must be openai, gemini, or grok")
variable, selector, item = credentials[provider]
if not environment.get(variable):
    credential = subprocess.run(
        ["/usr/bin/security", "find-generic-password", selector, item, "-w"],
        capture_output=True, check=False,
    )
    if credential.returncode or not credential.stdout.strip():
        sys.exit("Could not retrieve the selected provider's Keychain credential")
    environment[variable] = credential.stdout.decode().strip()
twilio = environment.get("ORDER_DESK_TWILIO")
if twilio in {"1", "incoming"}:
    accounts = {
        "account_sid": "TWILIO_ACCOUNT_SID", "auth_token": "TWILIO_AUTH_TOKEN",
        "phone_number_e164": "TWILIO_PHONE_NUMBER",
    }
    # Incoming calls need no caller SDK or routing-tool credentials. Keep the
    # existing full credential mode for development callers and routing leases.
    if twilio == "1":
        accounts.update({
            "voice_sdk_api_key_sid": "TWILIO_API_KEY_SID",
            "voice_sdk_api_key_secret": "TWILIO_API_KEY_SECRET",
            "phone_number_sid": "TWILIO_PHONE_NUMBER_SID",
        })
    for account, variable in accounts.items():
        if environment.get(variable):
            continue
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "cadence.twilio.development", "-a", account, "-w"],
            capture_output=True, check=False,
        )
        if result.returncode or not result.stdout.strip():
            sys.exit("Could not retrieve a required Twilio Keychain credential")
        environment[variable] = result.stdout.decode().rstrip("\n")
if environment.get("ORDER_DESK_TELNYX") == "1":
    accounts = {
        "api_key": "TELNYX_API_KEY", "phone_number_e164": "TELNYX_PHONE_NUMBER",
        "voice_api_connection_id": "TELNYX_VOICE_API_CONNECTION_ID",
        "webhook_public_key": "TELNYX_WEBHOOK_PUBLIC_KEY",
    }
    for account, variable in accounts.items():
        if environment.get(variable):
            continue
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "cadence.telnyx.development", "-a", account, "-w"],
            capture_output=True, check=False,
        )
        if result.returncode or not result.stdout.strip():
            sys.exit("Could not retrieve a required Telnyx Keychain credential")
        environment[variable] = result.stdout.decode().rstrip("\n")
if environment.get("ORDER_DESK_TYPESAFE") == "1" and not environment.get("TYPESAFE_API_KEY"):
    typesafe = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", "typesafe_ai", "-a", "api_key", "-w"],
        capture_output=True, check=False,
    )
    if typesafe.returncode or not typesafe.stdout.strip():
        sys.exit("Could not retrieve the TypeSafe Keychain credential")
    environment["TYPESAFE_API_KEY"] = typesafe.stdout.decode().rstrip("\n")
os.execvpe(sys.argv[1], sys.argv[1:], environment)
