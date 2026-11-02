import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from audit_caller_turns import audit


def transcript(at, text, segment="caller"):
    return {"kind": "event", "name": "transcript_delta", "at_ms": at,
            "data": {"speaker": "user", "delta": text, "segment_id": segment}}


def recording():
    return {"mode": "replay", "audio": {"sample_rate": 24000, "dropped_packets": 0,
             "chunks": [{"direction": "input", "at_ms": 74211.214}]},
            "event_log": {"dropped_events": 0},
            "events": [{"kind": "marker", "name": "input:caller_started", "at_ms": 74211.214,
                        "data": {"tick": 0, "bytes": 80640, "label": "choose"}},
                       transcript(76106.918, "Ten fifteen, please. ")]}


class CallerTurnAuditTest(unittest.TestCase):
    def test_recorded_cafe_false_turn_is_detected_despite_successful_booking(self):
        report = recording()
        report["passed"] = True
        report["events"].append(transcript(83107.679, "I'm your interview rep. ", "noise"))
        result = audit(report)
        self.assertFalse(result["passed"])
        self.assertEqual(result["unexpected_caller_turns"][0]["text"], "I'm your interview rep. ")
        self.assertEqual(result["untranscribed_clips"], [])

    def test_check_uses_input_evidence_instead_of_a_phrase_blacklist(self):
        report = recording()
        report["events"].append(transcript(83107.679, "Yes, book that.", "noise"))
        self.assertFalse(audit(report)["passed"])

    def test_legitimate_delayed_transcript_passes(self):
        self.assertTrue(audit(recording())["passed"])

    def test_one_word_no_is_valid_caller_speech(self):
        report = recording()
        report["events"][-1] = transcript(74700, "No")
        self.assertTrue(audit(report)["passed"])

    def test_fragmented_transcript_is_one_turn(self):
        report = recording()
        report["events"][-1] = transcript(74500, "Ten ")
        report["events"].append(transcript(76106, "fifteen, please. "))
        result = audit(report)
        self.assertTrue(result["passed"])
        self.assertEqual(result["caller_turns"], 1)

    def test_missing_speech_and_incomplete_capture_cannot_pass(self):
        report = recording()
        report["events"].pop()
        self.assertEqual(audit(report)["untranscribed_clips"], ["choose"])
        for section, field in [("audio", "dropped_packets"), ("event_log", "dropped_events")]:
            broken = recording()
            broken[section][field] = 1
            self.assertFalse(audit(broken)["passed"])

    def test_audit_does_not_modify_recorded_events(self):
        report = recording()
        previous = copy.deepcopy(report)
        audit(report)
        self.assertEqual(report, previous)

    def test_microphone_and_missing_actual_onset_markers_are_rejected(self):
        for mode in ["microphone", "replay"]:
            report = recording()
            report["mode"] = mode
            report["events"].pop(0)
            with self.assertRaises(ValueError):
                audit(report)


if __name__ == "__main__":
    unittest.main()
