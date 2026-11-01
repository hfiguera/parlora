#!/usr/bin/env python3
"""Generate caller-only PCM. Existing files are reused to bound paid generation."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import sys
import urllib.error
import urllib.request
import urllib.parse

API = "https://api.elevenlabs.io/v1"

def request(path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(API + path, data=body, headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        # Upstream response bodies may echo content. Retain status only.
        raise RuntimeError(f"ElevenLabs returned HTTP {error.code}") from None

def main():
    source = Path(__file__).resolve().parents[1] / "priv/caller.json"
    script = json.loads(source.read_text())
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("clips"))
    parser.add_argument("--voice", default=os.environ.get("ELEVENLABS_VOICE_ID", script["voice_id"]))
    parser.add_argument("--ids", default="search,identity,insurance,preparation,correction,choose,confirm,progress,reminder,phone_confirm,goodbye")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    model = script["model"]
    models = json.loads(request("/models"))
    voice = json.loads(request("/voices/" + urllib.parse.quote(args.voice, safe="")))
    metadata = validate_voice(models, voice, model)
    manifest = {"model": model, "voice_id": args.voice, "voice": metadata, "synthetic_caller": True, "sample_rate": 24000, "utterances": []}
    for row in script["utterances"]:
        if row["id"] not in args.ids.split(","):
            continue
        target = args.output / (row["id"] + ".pcm")
        payload, signature = generation_input(row, model, args.voice)
        provenance = target.with_suffix(".json")
        if not (target.exists() and provenance.exists() and json.loads(provenance.read_text()).get("signature") == signature):
            pcm = request("/text-to-dialogue?output_format=pcm_24000", payload)
            if len(pcm) % 2 or not pcm or len(pcm) > 24000 * 2 * 30:
                raise RuntimeError("Invalid or oversized PCM response")
            target.write_bytes(pcm)
            provenance.write_text(json.dumps({**row, "signature": signature, "model": model, "voice_id": args.voice}))
        pcm = target.read_bytes()
        manifest["utterances"].append({**row, "file": target.name, "duration_ms": len(pcm) / 48, "sha256": hashlib.sha256(pcm).hexdigest()})
        print(f'Caller clip: {row["id"]} ({len(pcm) / 48000:.1f}s)')
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

def validate_voice(models, voice, model):
    if model != "eleven_v4":
        raise RuntimeError("The caller demonstration requires eleven_v4; no model fallback is allowed")
    if not any(m.get("model_id") == model and m.get("can_do_text_to_speech") for m in models):
        raise RuntimeError("Eleven v4 is not available for speech synthesis")
    if model not in voice.get("high_quality_base_model_ids", []):
        raise RuntimeError("Choose a voice with explicitly listed Eleven v4 support")
    labels = voice.get("labels", {})
    return {"name": voice.get("name"), "accent": labels.get("accent"), "language": labels.get("language"), "listed_model": model}

def synthesis_text(row):
    text = row.get("speech_text", row["text"])
    spoken = re.sub(r"\[[^\[\]]+\]", "", text)
    words = lambda value: re.findall(r"[a-z0-9']+", value.lower())
    if words(spoken) != words(row["text"]):
        raise RuntimeError("Delivery tags must preserve the caller's spoken words")
    return text

def generation_input(row, model, voice):
    text = synthesis_text(row)
    payload = {"model_id": model, "inputs": [{"text": text, "voice_id": voice}]}
    if "previous_text" in row:
        context = row["previous_text"]
        if not isinstance(context, str) or not context.strip() or len(context) > 100:
            raise RuntimeError("Prosodic context must contain 1 to 100 characters")
        payload["previous_text"] = context
        signature = json.dumps(payload, sort_keys=True)
    else:
        # Preserve existing clip cache signatures when no conditioning is requested.
        signature = json.dumps([model, voice, text])
    return payload, hashlib.sha256(signature.encode()).hexdigest()

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError) as error:
        sys.exit(str(error))
