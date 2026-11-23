"""Prepare synthetic caller fixtures locally; never opens a microphone or plays audio."""
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
    "lookup": ("Samantha", "Please check order number one hundred twenty three."),
    "correction": ("Samantha", "Actually, I meant order number one hundred twenty four."),
    "spanish": ("Paulina", "¿Puedes repetir la fecha de entrega en español, por favor?"),
}
for name, (voice, text) in phrases.items():
    wav = directory / (name + ".wav")
    subprocess.run([
        "/usr/bin/say", "-v", voice, "-r", "165", "--file-format=WAVE",
        "--data-format=LEI16@24000", "-o", str(wav), text,
    ], check=True, capture_output=True)
    for suffix, rate, encoding in [("pcm", "24000", "s16le"), ("pcmu", "8000", "mulaw")]:
        subprocess.run([
            ffmpeg, "-v", "error", "-y", "-i", str(wav), "-ac", "1",
            "-ar", rate, "-f", encoding, str(directory / (name + "." + suffix)),
        ], check=True, capture_output=True)
print("Prepared three synthetic caller clips in PCM and PCMU")
