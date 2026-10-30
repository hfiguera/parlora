"""Generate synthetic PCM fixtures on macOS; no microphone or private audio is used."""
import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
args.directory.mkdir(parents=True, exist_ok=True)

phrases = {
    "lookup": "Please check the delivery status of order one hundred twenty three.",
    "correction": "Actually, I meant order one hundred twenty four instead.",
    "items": "What items are in that order?",
    "clarify": "I want to change the delivery instructions for that order.",
    "draft": "Leave it at reception.",
    "refusal": "No, do not save that. Keep the original instructions.",
    "newdraft": "For order one hundred twenty four, change the delivery instructions to leave it with my neighbor.",
}
for name, phrase in phrases.items():
    source = args.directory / f"{name}.aiff"
    target = args.directory / f"{name}.pcm"
    subprocess.run(["say", "-v", "Samantha", "-r", "165", "-o", str(source), phrase], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(source), "-f", "s16le", "-acodec", "pcm_s16le", "-ar", "24000", "-ac", "1", str(target)], check=True)
