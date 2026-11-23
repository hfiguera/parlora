"""Generate synthetic caller-only fixtures; never opens the microphone or speakers."""
from pathlib import Path
import shutil
import subprocess
import sys

directory = Path(sys.argv[1])
directory.mkdir(parents=True, exist_ok=True)
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg:
    sys.exit("ffmpeg is required")
phrases = {
    "search": "Please check November fifth with Doctor Lee.",
    "choose": "Ten fifteen in the morning, please.",
    "approve": "Yes, please.",
    "ack": "Okay.",
}
for name, text in phrases.items():
    wav = directory / (name + ".wav")
    subprocess.run([
        "/usr/bin/say", "-v", "Samantha", "-r", "210", "--file-format=WAVE",
        "--data-format=LEI16@24000", "-o", str(wav), text,
    ], check=True, capture_output=True)
    subprocess.run([
        ffmpeg, "-v", "error", "-y", "-i", str(wav), "-ac", "1", "-ar", "24000",
        "-f", "s16le", str(directory / (name + ".pcm")),
    ], check=True, capture_output=True)
