#!/usr/bin/env python3
"""Run development tooling with the existing Keychain secret in its environment."""
import os
import subprocess
import sys

if len(sys.argv) < 2:
    sys.exit("Usage: python3 scripts/with_keychain.py COMMAND [ARGS...]")
environment = os.environ.copy()
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
os.execvpe(sys.argv[1], sys.argv[1:], environment)
