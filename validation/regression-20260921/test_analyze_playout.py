"""Known-signal controls for the validation-only audio classifier."""

import base64
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


class AudioEvidenceTest(unittest.TestCase):
    def analyze(self, blocks):
        source_bytes = silence_bytes = 0
        rows = []
        for index, (source, sample) in enumerate(blocks):
            pcm = struct.pack("<240h", *([sample] * 240))
            source_bytes += len(pcm) if source else 0
            silence_bytes += 0 if source else len(pcm)
            rows.append({
                "pid": "fixture",
                "at_us": index * 10000,
                "pcm": base64.b64encode(pcm).decode(),
                "source_bytes": source_bytes,
                "silence_bytes": silence_bytes,
                "starvations": 1,
            })

        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "capture.json"
            capture.write_text(json.dumps({"at_bound": False, "frames": rows}))
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name("analyze_playout.py")), str(capture)],
                check=True, capture_output=True,
            )
            return json.loads(capture.with_name("audio-summary.json").read_text())

    def test_gap_between_active_samples_is_flagged(self):
        result = self.analyze([(False, 0), (True, 1000), (False, 0), (True, 1000)])
        self.assertEqual(result["signal_bounded_gaps"], 1)
        self.assertEqual(result["interior_gaps"][0]["inserted_ms"], 10)

    def test_gap_between_silent_source_blocks_is_not_speech_evidence(self):
        result = self.analyze([(False, 0), (True, 0), (False, 0), (True, 1)])
        self.assertEqual(len(result["interior_gaps"]), 1)
        self.assertEqual(result["signal_bounded_gaps"], 0)

    def test_trailing_silence_does_not_count_as_an_interior_gap(self):
        result = self.analyze([(False, 0), (True, 1000), (True, 1000), (False, 0)])
        self.assertEqual(result["interior_gaps"], [])


if __name__ == "__main__":
    unittest.main()
