"""Offline checks for the publication's PCM and event reconstruction boundary."""
import json
from pathlib import Path
import tempfile
import unittest

from booking_recordings import Recording, captions_from_words, pcm, samples, sha, phonic_caller_audit


class RecordingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.clips = self.root / "clips"
        self.clips.mkdir()
        self.voice = pcm([1000] * 240)
        self.silence = pcm([0] * 240)
        (self.clips / "search.pcm").write_bytes(self.voice)
        self.manifest = {"voice_id": "chosen", "model": "eleven_v4", "utterances": [
            {"id": "search", "file": "search.pcm", "sha256": sha(self.voice)}]}
        (self.clips / "manifest.json").write_text(json.dumps(self.manifest))
        chunks = []
        for tick, at in enumerate([50, 51, 70]):
            for direction in ["input", "output"]:
                chunks.append({"direction": direction, "offset": tick * 480, "bytes": 480, "at_ms": at})
        self.report = {"audio": {"sample_rate": 24000, "encoding": "pcm_s16le", "dropped_packets": 0, "chunks": chunks},
                       "event_log": {"dropped_events": 0}, "caller": self.manifest,
                       "events": [{"kind": "marker", "name": "caller:search", "at_ms": 51,
                                   "data": {"clip": "search"}}]}
        (self.root / "input.pcm").write_bytes(self.silence + self.voice + self.silence)
        (self.root / "output.pcm").write_bytes(self.silence * 3)
        self.save()

    def save(self):
        (self.root / "session.json").write_text(json.dumps(self.report))

    def test_scheduler_catchup_keeps_ordered_output_ticks_and_sample_duration(self):
        output = pcm([10] * 240 + [20] * 240 + [30] * 240)
        (self.root / "output.pcm").write_bytes(output)
        recording = Recording(self.root)
        self.assertEqual(recording.assistant, output)
        self.assertEqual(recording.duration_ms, 30)
        self.assertEqual(recording.clock(51), 10)
        self.assertEqual(recording.clock(60.5), 15)

    def test_missing_output_tick_is_silence_and_does_not_shift_later_speech(self):
        self.report["audio"]["chunks"] = [c for c in self.report["audio"]["chunks"]
                                             if not (c["direction"] == "output" and c["offset"] == 480)]
        self.report["audio"]["chunks"][-1]["offset"] = 480
        (self.root / "output.pcm").write_bytes(pcm([10] * 240 + [30] * 240))
        self.save()
        self.assertEqual(list(samples(Recording(self.root).assistant)), [10] * 240 + [0] * 240 + [30] * 240)

    def test_delayed_output_observation_keeps_its_tick_instead_of_using_nearest_time(self):
        for chunk, at in zip(self.report["audio"]["chunks"], [50, 75, 76, 76, 80, 80]):
            chunk["at_ms"] = at
        (self.root / "output.pcm").write_bytes(pcm([10] * 240 + [20] * 240 + [30] * 240))
        self.save()
        recording = Recording(self.root)
        self.assertEqual(list(samples(recording.assistant)), [10] * 240 + [20] * 240 + [30] * 240)
        self.assertEqual(recording.max_pair_skew_ms, 25)

    def test_clean_input_requires_exact_clips_and_silence_everywhere_else(self):
        result = Recording(self.root).verify_caller(self.clips)
        self.assertEqual(result["windows"], [{"label": "search", "start": 10, "end": 20}])
        (self.root / "input.pcm").write_bytes(pcm([1] * 240) + self.voice + self.silence)
        with self.assertRaisesRegex(ValueError, "Unexpected foreground"):
            Recording(self.root).verify_caller(self.clips)

    def test_cafe_subtraction_verifies_hash_phase_and_complete_caller(self):
        noise = pcm([100] * 240 + [-200] * 240)
        (self.root / "ambience.pcm").write_bytes(noise)
        self.report["ambience"] = {"pcm_sha256": sha(noise), "clipped_samples": 0,
                                   "caller_manifest_sha256": sha((self.clips / "manifest.json").read_bytes())}
        (self.root / "input.pcm").write_bytes(pcm([100] * 240 + [800] * 240 + [100] * 240))
        self.save()
        self.assertTrue(Recording(self.root).verify_caller(self.clips)["passed"])
        self.report["ambience"]["clipped_samples"] = 1
        self.save()
        with self.assertRaisesRegex(ValueError, "clipping"):
            Recording(self.root).verify_caller(self.clips)

    def test_incomplete_capture_is_rejected_before_publication(self):
        for kind, field in [("audio", "dropped_packets"), ("event_log", "dropped_events")]:
            self.report[kind][field] = 1
            self.save()
            with self.assertRaisesRegex(ValueError, "complete"):
                Recording(self.root)
            self.report[kind][field] = 0

    def test_replacement_does_not_invent_a_finish_or_result_for_old_work(self):
        self.report["events"] = [
            {"kind": "event", "name": "task_submitted", "at_ms": 50, "request_id": "old",
             "data": {"task_id": "calendar", "input": {"operation": "availability", "date": "2026-11-04"}}},
            {"kind": "telemetry", "name": "parlora.backend.start", "at_ms": 50.1,
             "data": {"request_id": "old"}},
            {"kind": "event", "name": "task_submitted", "at_ms": 51, "request_id": "new",
             "data": {"task_id": "calendar", "input": {"operation": "availability", "date": "2026-11-05"}}},
            {"kind": "event", "name": "request_completed", "source": "backend", "at_ms": 70,
             "request_id": "new", "data": {"status": "completed", "facts": {"date": "2026-11-05"}}},
        ]
        self.save()
        old, new = Recording(self.root).backend_activity()
        self.assertEqual(old["replaced_at"], new["submitted"])
        self.assertNotIn("end", old)
        self.assertNotIn("result", old)
        self.assertEqual(new["result"]["facts"]["date"], "2026-11-05")

    def test_captions_use_capture_channels_even_when_diarization_ids_are_equal(self):
        captions = captions_from_words([
            {"text": "Hello.", "start": 1, "end": 1.5, "type": "word", "channel_index": 1, "speaker_id": "same"},
            {"text": "Hi.", "start": 3, "end": 3.3, "type": "word", "channel_index": 0, "speaker_id": "same"},
        ])
        self.assertEqual(captions, [{"speaker": "assistant", "start": 1000, "end": 1500, "text": "Hello."},
                                    {"speaker": "user", "start": 3000, "end": 3300, "text": "Hi."}])
        with self.assertRaisesRegex(ValueError, "channel identity"):
            captions_from_words([{"text": "Unknown", "start": 0, "end": 1, "type": "word"}])

    def test_provider_captions_without_segment_ids_do_not_merge_the_entire_call(self):
        self.report["events"] = [
            {"kind": "event", "name": "transcript_delta", "at_ms": at,
             "data": {"speaker": speaker, "delta": text}}
            for at, speaker, text in [(50, "assistant", "Hello."), (51, "user", "Hi."),
                                      (70, "assistant", "How can I help?")]
        ]
        self.save()
        self.assertEqual([c["text"] for c in Recording(self.root).provider_captions()],
                         ["Hello.", "Hi.", "How can I help?"])

    def test_clean_phonic_audit_uses_verified_sample_offsets_without_rewriting_capture(self):
        self.report.update(provider="phonic", mode="replay")
        self.report["events"] += [
            {"kind": "event", "name": "extension", "at_ms": 51,
             "data": {"kind": "caller_speech", "state": "started", "segment_id": "caller-1"}},
            {"kind": "event", "name": "transcript_delta", "at_ms": 70,
             "data": {"speaker": "user", "segment_id": "caller-1", "delta": "Hi."}},
        ]
        self.save()
        recording = Recording(self.root)
        integrity = recording.verify_caller(self.clips)
        result = phonic_caller_audit(recording, integrity)
        self.assertTrue(result["passed"])
        self.assertEqual(result["onset_evidence"], "exact caller PCM offsets")
        self.assertFalse(any(e["name"] == "input:caller_started" for e in recording.report["events"]))
        self.assertEqual((self.root / "session.json").read_bytes(), recording.report_bytes)


if __name__ == "__main__":
    unittest.main()
