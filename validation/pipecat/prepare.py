# /// script
# requires-python = ">=3.11"
# dependencies = ["pyarrow==21.0.0"]
# ///
"""Freeze the public Pipecat corpus; no provider requests or credentials."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

DATASET = "pipecat-ai/stt-benchmark-data"
REVISION = "3fe50170d520c951957b86996ef082a6ab87b394"
PARQUET_SHA256 = "8888634e74784d26f2dce6a21d77af58280b94032d685b98b1fac172c1bfa7ce"
ROOT = Path(__file__).resolve().parent


def digest(path):
    with open(path, "rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def prepare(root):
    import pyarrow.parquet as pq

    root.mkdir(parents=True, exist_ok=True)
    parquet = root / "source.parquet"
    if not parquet.exists():
        url = f"https://huggingface.co/datasets/{DATASET}/resolve/{REVISION}/data/train-00000-of-00001.parquet"
        temporary = root / "source.parquet.part"
        urllib.request.urlretrieve(url, temporary)
        if digest(temporary) != PARQUET_SHA256:
            raise ValueError("Downloaded parquet checksum mismatch")
        temporary.rename(parquet)
    if digest(parquet) != PARQUET_SHA256:
        raise ValueError("Cached parquet checksum mismatch")

    rows = pq.read_table(parquet).to_pylist()
    if len(rows) != 1000 or len({r["sample_id"] for r in rows}) != 1000:
        raise ValueError("Expected 1,000 distinct source samples")
    # Stable pseudo-random order, independent of Python random implementations.
    rows.sort(key=lambda r: hashlib.sha256(("parlora-pipecat-v1:42:" + r["sample_id"]).encode()).digest())
    audio_dir = root / "audio"
    audio_dir.mkdir(exist_ok=True)
    samples = []
    for index, row in enumerate(rows):
        sample_id = row["sample_id"]
        if not row["transcription"].strip():
            raise ValueError(f"Empty reference: {sample_id}")
        source = audio_dir / f"{sample_id}.source"
        source.write_bytes(row["audio"]["bytes"])
        pcm = audio_dir / f"{sample_id}.pcm"
        # A deterministic, explicitly recorded 16 -> 24 kHz derivative.
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(source),
                        "-ac", "1", "-ar", "24000", "-c:a", "pcm_s16le", "-f", "s16le", str(pcm)], check=True)
        size = pcm.stat().st_size
        duration = size / 48000
        if size % 2 or not 0 < duration <= 20 or abs(duration - row["duration_seconds"]) > .02:
            raise ValueError(f"Unexpected decoded duration: {sample_id}")
        samples.append({"sample_id": sample_id, "reference": row["transcription"],
                        "source_duration_seconds": row["duration_seconds"],
                        "duration_ms": size / 48, "pcm_bytes": size,
                        "pcm_path": str(pcm.relative_to(root)), "pcm_sha256": digest(pcm),
                        "source_sha256": digest(source), "pilot": index < 20})
    ffmpeg = subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0]
    manifest = {"schema_version": 1, "dataset": DATASET, "revision": REVISION,
                "parquet_sha256": PARQUET_SHA256, "selection": "sha256(parlora-pipecat-v1:42: + sample_id)",
                "source_split": "train", "usage": "evaluation", "source_sample_rate": 16000,
                "format": "pcm_s16le/24000/mono", "ffmpeg": ffmpeg,
                "license": "No explicit dataset license declared in the pinned dataset card; audio stays local.",
                "samples": samples}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"manifest": str(root / "manifest.json"), "samples": len(samples),
                      "pilot": 20, "audio_minutes": sum(s["duration_ms"] for s in samples) / 60000}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".cache")
    prepare(parser.parse_args().output.resolve())
