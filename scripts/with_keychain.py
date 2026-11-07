#!/usr/bin/env python3
"""Run development tooling with existing Keychain credentials in its environment."""
import os
import subprocess
import sys

command = sys.argv[1:]
booking_desk = command[:1] == ["--booking-desk"]
if booking_desk:
    command = command[1:]
if not command:
    sys.exit("Usage: python3 scripts/with_keychain.py [--booking-desk] COMMAND [ARGS...]")
environment = os.environ.copy()
if booking_desk and sys.platform == "darwin" and not environment.get("ERL_FLAGS"):
    # Match the local voice launcher's scheduler settings for audio polling.
    environment["ERL_FLAGS"] = "+sbwt none +sbwtdcpu none +sbwtdio none"
provider = environment.get("PARLORA_PROVIDER", "openai")
credentials = {
    "openai": ("OPENAI_API_KEY", "-l", "keel-openai-development"),
    "gemini": ("GEMINI_API_KEY", "-s", "parlora-gemini-development"),
    "grok": ("XAI_API_KEY", "-s", "parlora-grok-development"),
    "phonic": ("PHONIC_API_KEY", "-s", "parlora-phonic-development"),
    "prism": ("RIME_API_KEY", "-s", "parlora-prism-development"),
}
if provider not in credentials:
    sys.exit("PARLORA_PROVIDER must be openai, gemini, grok, phonic, or prism")
required = [credentials[provider]]
if booking_desk:
    required.extend([
        credentials["openai"],
        ("TYPESAFE_API_KEY", "-s", "typesafe_ai", "-a", "api_key"),
    ])

for variable, *selector in required:
    if environment.get(variable):
        continue
    credential = subprocess.run(
        ["/usr/bin/security", "find-generic-password", *selector, "-w"],
        capture_output=True, check=False,
    )
    if credential.returncode or not credential.stdout.strip():
        sys.exit(f"Could not retrieve the Keychain credential for {variable}")
    environment[variable] = credential.stdout.decode().strip()
os.execvpe(command[0], command, environment)
