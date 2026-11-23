"""Copy the full replay with a synthetic version of the recorded suffix echo."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

source, output = map(Path, sys.argv[1:])
shutil.copytree(source, output, dirs_exist_ok=True)
text = "One eight eight? Yes, that is my number."
wav = output / "phone_confirm.wav"
pcm = output / "phone_confirm.pcm"
subprocess.run([
    "/usr/bin/say", "-v", "Samantha", "-r", "190", "--file-format=WAVE",
    "--data-format=LEI16@24000", "-o", str(wav), text,
], check=True, capture_output=True)
subprocess.run([
    "ffmpeg", "-v", "error", "-y", "-i", str(wav), "-ac", "1", "-ar", "24000",
    "-f", "s16le", str(pcm),
], check=True, capture_output=True)
manifest_path = output / "manifest.json"
manifest = json.loads(manifest_path.read_text())
override = {
    "id": "phone_confirm", "text": text, "speech_text": text,
    "file": pcm.name, "duration_ms": pcm.stat().st_size / 48,
    "sha256": hashlib.sha256(pcm.read_bytes()).hexdigest(),
    "model": "macOS say", "voice": "Samantha",
}
manifest["utterances"] = [
    override if row["id"] == "phone_confirm" else row for row in manifest["utterances"]
]
manifest["model"] = "mixed synthetic fixtures; phone_confirm uses macOS say"
manifest["voice"] = {"name": "Original fixture voices plus Samantha for phone_confirm"}
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
(output / "phone_confirm.json").write_text(json.dumps(override, indent=2) + "\n")
