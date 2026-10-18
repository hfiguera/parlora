import hashlib
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from score import errors, score, words


class ScoringTest(unittest.TestCase):
    def test_word_distance_keeps_number_and_negation_errors(self):
        self.assertEqual(errors(words("do not save order 123"), words("do save order 124")), 2)
        self.assertEqual(errors(words("Hello, WORLD!"), words("hello world")), 0)
        self.assertEqual(errors(words("one two three"), []), 3)
        self.assertEqual(errors([], words("hallucinated word")), 2)

    def test_deadlines_and_failed_samples_cannot_improve_denominator(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = [{"sample_id": "a", "reference": "do not save", "duration_ms": 1000, "pilot": True},
                       {"sample_id": "b", "reference": "order 124", "duration_ms": 1000, "pilot": True}]
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"samples": samples}))
            metadata = {"manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
                        "mode": "live", "planned_ids": ["a", "b"], "tail_ms": 3000,
                        "dataset": "fixture", "dataset_revision": "fixture"}
            (root / "run.json").write_text(json.dumps(metadata))
            (root / "a.json").write_text(json.dumps({"sample_id": "a", "mode": "live", "status": "ok",
                  "events": [{"at_ms": 1100, "delta": "do "}, {"at_ms": 1501, "delta": "not save"}],
                  "pacing": {"max_late_ms": 1}}))
            with contextlib.redirect_stdout(io.StringIO()):
                result = score(manifest, root)
            self.assertEqual(result["reference_words"], 5)
            self.assertEqual(result["pooled_wer_by_clip_end_deadline_ms"]["500"], .8)
            self.assertEqual(result["pooled_wer_by_clip_end_deadline_ms"]["1000"], .4)
            self.assertEqual(result["status_counts"]["not_attempted"], 1)
            self.assertFalse(result["pilot_sanity_gate"])
            strict_report = (root / "score.json").read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                supplemental = score(manifest, root, numeric=True)
            self.assertEqual((root / "score.json").read_bytes(), strict_report)
            self.assertEqual(supplemental["pooled_wer_by_clip_end_deadline_ms"], result["pooled_wer_by_clip_end_deadline_ms"])
            self.assertEqual(supplemental["numeric_meaning"]["reference_entities_in_automatic_score"], 1)
            self.assertEqual(supplemental["numeric_meaning"]["entity_edits_in_automatic_score"], 1)
            self.assertTrue((root / "score-numeric.json").exists())
            manifest.write_text("{}")
            with self.assertRaises(ValueError):
                score(manifest, root)

    def test_late_caption_does_not_count_as_available_at_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"samples": [{"sample_id": "a", "reference": "hello",
                                                         "duration_ms": 1000, "pilot": True}]}))
            (root / "run.json").write_text(json.dumps({
                "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
                "mode": "live", "planned_ids": ["a"], "tail_ms": 3000,
                "dataset": "fixture", "dataset_revision": "fixture"}))
            (root / "a.json").write_text(json.dumps({
                "sample_id": "a", "mode": "live", "status": "ok",
                "close": {"cleaned_up": True, "finalized": True, "late_events": [{"at_ms": 4010, "delta": "hello"}]},
                "events": [{"at_ms": 4001, "delta": "hello"}],
                "pacing": {"max_late_ms": 1}}))
            (root / "completion.json").write_text(json.dumps({"status": "ok", "active_sessions": 0}))
            with contextlib.redirect_stdout(io.StringIO()):
                result = score(manifest, root)
            self.assertEqual(result["pooled_wer_by_clip_end_deadline_ms"]["3000"], 1.0)
            self.assertTrue(result["infrastructure_ok"])
            self.assertFalse(result["transcript_coverage_complete"])
            self.assertFalse(result["pilot_sanity_gate"])

    def test_recovered_coverage_verifies_preserved_results_without_overwriting_first_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prior = root / "prior"
            current = root / "continued"
            prior.mkdir()
            current.mkdir()
            samples = [{"sample_id": x, "reference": "hello", "duration_ms": 1000, "pilot": True}
                       for x in ["a", "b"]]
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"samples": samples}))
            for run, sample_id in [(prior, "a"), (current, "b")]:
                (run / (sample_id + ".json")).write_text(json.dumps({
                    "sample_id": sample_id, "mode": "live", "status": "ok",
                    "events": [{"at_ms": 500, "delta": "hello"}],
                    "close": {"cleaned_up": True, "finalized": True},
                    "pacing": {"max_late_ms": 1}}))
            rejected = prior / "b.json"
            rejected.write_text(json.dumps({"sample_id": "b", "status": "failed"}))
            rejected_bytes = rejected.read_bytes()
            old = prior / "a.json"
            (current / "run.json").write_text(json.dumps({
                "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
                "mode": "live", "planned_ids": ["b"], "tail_ms": 3000,
                "dataset": "fixture", "dataset_revision": "fixture",
                "preserved_successes": {"a": {"path": str(old), "sha256": hashlib.sha256(old.read_bytes()).hexdigest()}}}))
            (current / "completion.json").write_text(json.dumps({"status": "ok", "active_sessions": 0}))
            with contextlib.redirect_stdout(io.StringIO()):
                report = score(manifest, current, include_preserved=True)
            self.assertEqual(report["planned"], 2)
            self.assertEqual(report["preserved_prior_successes"], 1)
            self.assertEqual(report["cohort"], "recovered coverage")
            self.assertEqual(report["pooled_wer_by_clip_end_deadline_ms"]["3000"], 0)
            self.assertEqual(rejected.read_bytes(), rejected_bytes)
            self.assertTrue((current / "score-recovered.json").exists())
            old.write_text("{}")
            with self.assertRaisesRegex(ValueError, "Preserved result checksum mismatch"):
                score(manifest, current, include_preserved=True)


if __name__ == "__main__":
    unittest.main()
