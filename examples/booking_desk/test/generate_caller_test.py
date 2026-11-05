import sys
import hashlib
import json
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from generate_caller import validate_voice, synthesis_text, generation_input


class VoiceCompatibilityTest(unittest.TestCase):
    def setUp(self):
        self.models = [{"model_id": "eleven_v4", "can_do_text_to_speech": True}]
        self.voice = {"name": "Caleb - Trusted Guide", "high_quality_base_model_ids": ["eleven_v4"], "labels": {"accent": "american", "language": "en"}, "private_metadata": "omit"}

    def test_verified_voice_metadata_is_small_and_explicit(self):
        self.assertEqual(validate_voice(self.models, self.voice, "eleven_v4"), {"name": "Caleb - Trusted Guide", "accent": "american", "language": "en", "listed_model": "eleven_v4"})

    def test_older_model_cannot_be_silently_substituted(self):
        with self.assertRaisesRegex(RuntimeError, "no model fallback"):
            validate_voice(self.models, self.voice, "eleven_v3")

    def test_missing_model_or_unlisted_voice_stops_before_generation(self):
        for models, voice in [( [], self.voice), (self.models, {**self.voice, "high_quality_base_model_ids": []})]:
            with self.assertRaises(RuntimeError):
                validate_voice(models, voice, "eleven_v4")

    def test_instant_clone_without_model_metadata_can_reach_explicit_v4_synthesis(self):
        for listed in [[], None]:
            voice = {**self.voice, "category": "cloned", "high_quality_base_model_ids": listed}
            metadata = validate_voice(self.models, voice, "eleven_v4")
            self.assertIsNone(metadata["listed_model"])
            payload, _ = generation_input({"text": "Ten fifteen, please."}, "eleven_v4", "clone-id")
            self.assertEqual(payload["model_id"], "eleven_v4")
            self.assertEqual(payload["inputs"][0]["voice_id"], "clone-id")

    def test_clone_exception_does_not_allow_an_unavailable_model_or_conflicting_model_list(self):
        voice = {**self.voice, "category": "cloned", "high_quality_base_model_ids": []}
        with self.assertRaisesRegex(RuntimeError, "not available"):
            validate_voice([], voice, "eleven_v4")
        with self.assertRaisesRegex(RuntimeError, "explicitly listed"):
            validate_voice(self.models, {**voice, "high_quality_base_model_ids": ["eleven_multilingual_v2"]}, "eleven_v4")

    def test_delivery_cues_reach_synthesis_without_changing_spoken_words(self):
        row = {"text": "Actually, Thursday would work better.", "speech_text": "[thoughtful] Actually... [pause] Thursday would work better."}
        self.assertEqual(synthesis_text(row), row['speech_text'])
        self.assertEqual(synthesis_text({'text': 'Is it booked yet?'}), 'Is it booked yet?')

    def test_tagged_script_cannot_silently_change_an_appointment_date(self):
        with self.assertRaisesRegex(RuntimeError, 'preserve'):
            synthesis_text({'text': 'Thursday November fifth.', 'speech_text': '[confident] Friday November sixth.'})

    def test_prosodic_context_reaches_the_request_and_invalidates_cached_audio(self):
        row = {"text": "Yeah, go ahead and book it.", "speech_text": "[relaxed, conversational] Yeah, go ahead and book it.",
               "previous_text": "Shall I book that?"}
        payload, signature = generation_input(row, "eleven_v4", "caleb")
        self.assertEqual(payload["previous_text"], "Shall I book that?")
        self.assertEqual(payload["inputs"][0]["text"], row["speech_text"])
        _, other = generation_input({**row, "previous_text": "Does that work?"}, "eleven_v4", "caleb")
        self.assertNotEqual(signature, other)

    def test_unchanged_utterances_keep_their_existing_cache_keys(self):
        row = {"text": "Ten fifteen, please.", "speech_text": "[conversational] Ten fifteen, please."}
        payload, signature = generation_input(row, "eleven_v4", "caleb")
        self.assertNotIn("previous_text", payload)
        self.assertEqual(signature, hashlib.sha256(json.dumps(["eleven_v4", "caleb", row["speech_text"]]).encode()).hexdigest())

    def test_invalid_context_stops_before_a_billable_request(self):
        for value in [None, "", "x" * 101]:
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, "1 to 100"):
                generation_input({"text": "Go ahead.", "previous_text": value}, "eleven_v4", "caleb")


if __name__ == "__main__":
    unittest.main()
