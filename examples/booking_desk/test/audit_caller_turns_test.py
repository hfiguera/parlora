import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from audit_caller_turns import audit


def transcript(at, text, segment="caller"):
    return {"kind": "event", "name": "transcript_delta", "at_ms": at,
            "data": {"speaker": "user", "delta": text, "segment_id": segment}}


def speech(at, state="started", segment="caller"):
    return {"kind": "event", "name": "extension", "at_ms": at,
            "data": {"kind": "caller_speech", "state": state, "segment_id": segment}}


def recording():
    return {"mode": "replay", "provider": "phonic",
            "audio": {"sample_rate": 24000, "dropped_packets": 0,
             "chunks": [{"direction": "input", "at_ms": 74211.214}]},
            "event_log": {"dropped_events": 0},
            "events": [{"kind": "marker", "name": "input:caller_started", "at_ms": 74211.214,
                        "data": {"tick": 0, "bytes": 80640, "label": "choose"}},
                       speech(74500),
                       transcript(76106.918, "Ten fifteen, please. ")]}


class CallerTurnAuditTest(unittest.TestCase):
    def test_cafe_interruption_fails_even_when_its_punctuation_is_not_caller_dialogue(self):
        report = recording()
        report["events"].extend([
            speech(77314.375, segment="noise"),
            speech(106376.745, "finished", "noise"),
            {"kind": "event", "name": "extension", "at_ms": 106378.763,
             "data": {"kind": "transcript_discarded", "delta": ".", "segment_id": "noise"}}
        ])
        result = audit(report)
        self.assertFalse(result["passed"])
        self.assertEqual(result["unexpected_caller_turns"], [])
        self.assertEqual(result["unexpected_speech_starts"][0]["segment_id"], "noise")

    def test_phonic_recordings_without_speech_boundaries_cannot_prove_no_false_interruptions(self):
        report = recording()
        report["events"] = [e for e in report["events"] if e["name"] != "extension"]
        result = audit(report)
        self.assertFalse(result["passed"])
        self.assertFalse(result["speech_boundaries_recorded"])

    def test_cancellation_and_finish_are_not_additional_speech_starts(self):
        report = recording()
        report["events"].extend([speech(76000, "finished"), speech(76001, "cancelled")])
        result = audit(report)
        self.assertTrue(result["passed"])
        self.assertEqual(result["caller_speech_starts"], 1)

    def test_other_providers_do_not_require_phonic_specific_events(self):
        report = recording()
        report["provider"] = "openai"
        report["events"] = [e for e in report["events"] if e["name"] != "extension"]
        self.assertTrue(audit(report)["passed"])

    def test_cancellation_without_a_new_speech_start_is_still_checked(self):
        report = recording()
        report["events"].append({"kind": "event", "name": "output_interrupted",
                                 "source": "provider", "at_ms": 77314.375, "data": {}})
        result = audit(report)
        self.assertFalse(result["passed"])
        self.assertEqual(result["unexpected_output_interruptions"], [{"at_ms": 77314.375}])

    def test_real_caller_interruption_within_the_clip_is_valid(self):
        report = recording()
        report["events"].append({"kind": "event", "name": "output_interrupted",
                                 "source": "provider", "at_ms": 74500, "data": {}})
        self.assertTrue(audit(report)["passed"])

    def test_partial_boundary_capture_cannot_hide_another_caller_turn(self):
        report = recording()
        report["events"].append(transcript(74700, "No", "missing-start"))
        result = audit(report)
        self.assertFalse(result["passed"])
        self.assertEqual(result["caller_turns_without_speech_starts"][0]["segment_id"], "missing-start")

    def test_start_without_a_transcript_cannot_pass_even_inside_a_real_clip(self):
        report = recording()
        report["events"].append(speech(74700, segment="noise"))
        result = audit(report)
        self.assertFalse(result["passed"])
        self.assertEqual(result["untranscribed_speech_starts"][0]["segment_id"], "noise")

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

    def test_old_punctuation_false_turn_still_fails_the_audit(self):
        report = recording()
        report["events"].append(transcript(98059.319, ". ", "noise"))
        self.assertFalse(audit(report)["passed"])

    def test_discarded_non_speech_is_reported_separately_from_caller_turns(self):
        report = recording()
        report["events"].append({"kind": "event", "name": "extension", "at_ms": 98059.319,
                                 "data": {"kind": "transcript_discarded", "cause": "no_lexical_content",
                                          "speaker": "user", "delta": ".", "segment_id": "noise"}})
        result = audit(report)
        self.assertTrue(result["passed"])
        self.assertEqual(result["caller_turns"], 1)
        self.assertEqual(result["discarded_non_speech_transcripts"][0]["delta"], ".")

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
