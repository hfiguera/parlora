"""Check the deployment boundary: links, public analytics and source exclusion."""

from pathlib import Path
from html import unescape
import json
import hashlib
import re
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

from build import BEACON, SOURCE, Page, build, verify


class PublicationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / "site"

    def test_preview_has_working_links_and_no_analytics_or_development_files(self):
        build(self.output)
        self.assertEqual(verify(self.output), 6)
        for path in self.output.rglob("*.html"):
            self.assertNotIn(BEACON, path.read_text())
        self.assertFalse((self.output / "site.json").exists())
        self.assertFalse((self.output / "templates").exists())
        self.assertFalse((self.output / "PRODUCT.md").exists())

    def test_booking_assets_are_exactly_the_recordings_and_charts_used_by_the_article(self):
        article = (SOURCE / "content/keep-talking-while-we-book-it.html").read_text()
        recordings = re.findall(r'<option value="([^"]+)">', article)
        self.assertEqual(len(recordings), 8)
        folder = SOURCE / "assets/booking"
        expected = {"lookup-correction.svg", "booking-progress.svg"}
        for name in recordings:
            metadata = folder / (name + ".json")
            recording = json.loads(metadata.read_text())
            audio = metadata.parent / recording["audio"]
            self.assertEqual(hashlib.sha256(audio.read_bytes()).hexdigest(), recording["audio_sha256"])
            expected.update([metadata.relative_to(folder).as_posix(), audio.relative_to(folder).as_posix()])
        self.assertEqual({p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file()}, expected)

    def test_booking_refresh_uses_one_caller_and_measured_audio_for_every_recording(self):
        reference = json.loads((SOURCE / "assets/booking/clean/openai.json").read_text())["caller"]["utterances"]
        clips = {row["id"]: row["sha256"] for row in reference}
        for condition in ["", "clean/"]:
            for provider in ["openai", "phonic", "grok", "gemini"]:
                with self.subTest(condition=condition, provider=provider):
                    data = json.loads((SOURCE / f"assets/booking/{condition}{provider}.json").read_text())
                    self.assertEqual(data["caller"]["voice_id"], "h25UPLYkx8kiKcfh16Ha")
                    self.assertEqual(data["caller"]["model"], "eleven_v4")
                    captured = {row["id"]: row["sha256"] for row in data["caller"]["utterances"]}
                    for window in data["input_integrity"]["windows"]:
                        self.assertEqual(captured[window["label"]], clips[window["label"]])
                    self.assertEqual(data["caption_source"]["kind"], "offline_audio_transcription")
                    self.assertEqual(data["caption_source"]["pcm_sha256"], data["waveform_source"]["pcm_sha256"])
                    self.assertTrue(data["input_integrity"]["passed"])
                    self.assertEqual(data["passed"], all(data["checks"].values()))
                    self.assertEqual(data["metrics"]["workflow_checks_passed"], sum(data["checks"].values()))
                    self.assertEqual(data["duration_ms"], data["metrics"]["recorded_duration_ms"])
                    for caption in data["captions"]:
                        self.assertLessEqual(0, caption["start"])
                        self.assertLessEqual(caption["start"], caption["end"])
                        self.assertLessEqual(caption["end"], data["duration_ms"])

    def test_booking_graphs_are_derived_from_the_current_cafe_player_recording(self):
        metadata = SOURCE / "assets/booking/openai.json"
        data = json.loads(metadata.read_text())
        for name in ["lookup-correction", "booking-progress"]:
            svg = ET.parse(SOURCE / f"assets/booking/{name}.svg").getroot()
            description = svg.find(".//{http://purl.org/dc/elements/1.1/}description")
            evidence = json.loads(description.text)
            self.assertEqual(evidence["recording_sha256"], hashlib.sha256(metadata.read_bytes()).hexdigest())
            self.assertEqual(evidence["report_sha256"], data["caption_source"]["report_sha256"])
            self.assertEqual(evidence["input_pcm_sha256"], data["waveform_source"]["pcm_sha256"]["input"])

    def test_refreshed_reminder_wording_uses_original_captured_audio_and_one_caller_clip(self):
        refreshed = 0
        phone_hashes = set()
        for prefix in ["", "clean/"]:
            for provider in ["openai", "phonic", "grok", "gemini"]:
                data = json.loads((SOURCE / f"assets/booking/{prefix}{provider}.json").read_text())
                self.assertNotIn("audio_presentation", data)
                if not data.get("source_revision_base"):
                    continue
                refreshed += 1
                clip = next(row for row in data["caller"]["utterances"] if row["id"] == "phone_confirm")
                self.assertEqual(clip["text"], "Yep, that's the right number.")
                phone_hashes.add(clip["sha256"])
                processing = data["caller_preprocessing"]
                progress = next(row for row in data["caller"]["utterances"] if row["id"] == "progress")
                self.assertEqual(progress["sha256"], processing["replacement_clip_sha256"])
                self.assertTrue(data["input_integrity"]["passed"])
                if data["passed"]:
                    self.assertEqual(data["input_integrity"]["verified_clips"], 11)
                if any(window["label"] == "phone_confirm" for window in data["input_integrity"]["windows"]):
                    caller_text = " ".join(c["text"] for c in data["captions"] if c["speaker"] == "user").lower()
                    self.assertIn("right number", caller_text)
                    self.assertNotIn("my cell", caller_text)
        self.assertEqual(refreshed, 8)
        self.assertEqual(len(phone_hashes), 1)

    def test_all_eight_recordings_share_the_contextual_morning_selection_clip(self):
        article = (SOURCE / "content/keep-talking-while-we-book-it.html").read_text()
        hashes = set()
        for prefix in ["", "clean/"]:
            for provider in ["openai", "phonic", "grok", "gemini"]:
                data = json.loads((SOURCE / f"assets/booking/{prefix}{provider}.json").read_text())
                choice = next(row for row in data["caller"]["utterances"] if row["id"] == "choose")
                self.assertEqual(choice["text"], "The morning one, please.")
                hashes.add(choice["sha256"])
                if any(window["label"] == "choose" for window in data["input_integrity"]["windows"]):
                    words = " ".join(c["text"] for c in data["captions"] if c["speaker"] == "user")
                    self.assertIn("morning one", words.lower())
                proposals = [job for job in data["backend_activity"] if job["operation"] == "propose"]
                self.assertEqual(len(proposals), 1)
                self.assertEqual(proposals[0]["input"]["slot"], "2026-11-05T10:15:00")
                self.assertEqual(proposals[0]["input"]["clinician"], "lee")
        self.assertEqual(len(hashes), 1)
        self.assertIn("The morning one, please.", article)

    def test_phonic_recordings_use_normal_speed_and_match_the_published_outcomes(self):
        article = (SOURCE / "content/keep-talking-while-we-book-it.html").read_text()
        data = json.loads((SOURCE / "assets/booking/phonic.json").read_text())
        clean = json.loads((SOURCE / "assets/booking/clean/phonic.json").read_text())
        cafe = json.loads((SOURCE / "assets/booking/openai.json").read_text())
        self.assertTrue(data["passed"])
        self.assertEqual(data["outcome"], "completed")
        self.assertEqual(sum(data["checks"].values()), 14)
        self.assertEqual(data["metrics"]["new_bookings"], 1)
        self.assertEqual(data["metrics"]["simulated_reminders"], 1)
        effective = {**data["provider_defaults"], **data["provider_options"]}
        clean_effective = {**clean["provider_defaults"], **clean["provider_options"]}
        self.assertEqual(effective.pop("vad_threshold"), 0.8)
        self.assertEqual(clean_effective.pop("vad_threshold"), 0.8)
        self.assertEqual(effective, clean_effective)
        self.assertEqual(data["provider_defaults"]["vad_threshold"], 0.7)
        self.assertEqual(effective["audio_speed"], 1.0)
        self.assertEqual(clean["provider_defaults"]["audio_speed"], 1.0)
        self.assertNotIn("audio_speed", clean["provider_options"])
        self.assertEqual(data["ambience"]["pcm_sha256"], cafe["ambience"]["pcm_sha256"])
        self.assertEqual(data["ambience"]["gain"], cafe["ambience"]["gain"])
        self.assertTrue(data["caller_turn_audit"]["passed"])
        for key in ["unexpected_caller_turns", "unexpected_speech_starts",
                    "untranscribed_speech_starts", "unexpected_output_interruptions"]:
            self.assertEqual(data["caller_turn_audit"][key], [])
        questions = [caption for caption in data["captions"]
                     if caption["speaker"] == "assistant" and re.search(
                         r"number.*(?:zero one eight eight|0188)", caption["text"], re.I)]
        self.assertEqual(len(questions), 1)
        self.assertEqual(data["input_integrity"]["verified_clips"], 11)
        row = re.search(r'<tr><th scope="row">Phonic-1</th>(.*?)</tr>', article).group(1)
        for recording, cell in zip([clean, data], re.findall(r'<td>(.*?)</td>', row)):
            self.assertTrue(recording["passed"])
            self.assertEqual(recording["metrics"]["workflow_checks_passed"], 14)
            self.assertEqual(recording["metrics"]["new_bookings"], 1)
            self.assertEqual(recording["metrics"]["simulated_reminders"], 1)
            self.assertNotIn("audio_presentation", recording)
            seconds = recording["duration_ms"] // 1000
            self.assertIn(f"{seconds // 60}:{seconds % 60:02d}", cell)
            self.assertIn("14/14 checks", cell)
            self.assertIn("Completed", cell)
        self.assertNotIn('Phonic-1 · reminder incomplete', article)
        self.assertTrue(clean["caller_turn_audit"]["passed"])

    def test_refreshed_grok_players_and_article_use_the_same_results_and_configuration(self):
        article = (SOURCE / "content/keep-talking-while-we-book-it.html").read_text()
        row = re.search(r'<tr><th scope="row">Grok Voice 3.0</th>(.*?)</tr>', article).group(1)
        cells = re.findall(r'<td>(.*?)</td>', row)
        self.assertEqual(len(cells), 2)
        for prefix, cell in zip(["clean/", ""], cells):
            data = json.loads((SOURCE / f"assets/booking/{prefix}grok.json").read_text())
            seconds = int(data["duration_ms"] // 1000)
            self.assertIn(f"{seconds // 60}:{seconds % 60:02d}", cell)
            self.assertIn(f'{sum(data["checks"].values())}/{len(data["checks"])} checks', cell)
            self.assertTrue(data["passed"])
            self.assertEqual(data["metrics"]["new_bookings"], 1)
            self.assertEqual(data["metrics"]["simulated_reminders"], 1)
            self.assertEqual(data["assistant_voice"], "ara")
            self.assertEqual(data["provider_options"]["speed"], 1.0)
            self.assertIsNone(data["provider_options"]["idle_timeout_ms"])
            self.assertEqual(data["provider_options"]["replace"], {})
        self.assertNotIn('Grok Voice 3.0 · reminder incomplete', article)

    def test_refreshed_gemini_pair_results_and_settings_match_the_article(self):
        article = (SOURCE / "content/keep-talking-while-we-book-it.html").read_text()
        row = re.search(r'<tr><th scope="row">Gemini 3.8 Live</th>(.*?)</tr>', article).group(1)
        cells = re.findall(r'<td>(.*?)</td>', row)
        self.assertEqual(len(cells), 2)
        recordings = []
        for prefix, cell in zip(["clean/", ""], cells):
            data = json.loads((SOURCE / f"assets/booking/{prefix}gemini.json").read_text())
            recordings.append(data)
            seconds = int(data["duration_ms"] // 1000)
            self.assertIn(f"{seconds // 60}:{seconds % 60:02d}", cell)
            self.assertIn(f'{sum(data["checks"].values())}/{len(data["checks"])} checks', cell)
            self.assertEqual(data["assistant_voice"], "Sulafat")
            self.assertTrue(data["input_integrity"]["passed"])
            options = data["provider_options"]
            self.assertEqual(options["input_audio_transcription"]["mode"], "verbatim")
            self.assertEqual(options["input_audio_transcription"]["language_codes"], ["en-US"])
            detection = options["realtime_input_config"]["automatic_activity_detection"]
            self.assertEqual(detection["start_of_speech_sensitivity"], "low")
            self.assertEqual(detection["end_of_speech_sensitivity"], "low")
            self.assertEqual(detection["prefix_padding_ms"], 120)
            if prefix:
                self.assertTrue(data["passed"])
                self.assertEqual(data["metrics"]["new_bookings"], 1)
                self.assertEqual(data["metrics"]["simulated_reminders"], 1)
                self.assertEqual(data["input_integrity"]["verified_clips"], 11)
                self.assertIsNone(data["ambience"])
                verification = data["upstream_verification"]
                self.assertTrue(verification["all_chunks_preserved"])
                self.assertGreater(verification["chunk_count"], 0)
                self.assertEqual(verification["inserted_gaps_with_audible_edges"], 0)
                self.assertEqual(verification["output_pcm_sha256"], data["waveform_source"]["pcm_sha256"]["output"])
                self.assertIn("Completed", cell)
            else:
                self.assertIn("Completed" if data["passed"] else "Workflow incomplete", cell)
                self.assertEqual(data["ambience"]["pcm_sha256"], json.loads((SOURCE / "assets/booking/openai.json").read_text())["ambience"]["pcm_sha256"])
                self.assertEqual(data["ambience"]["gain"], json.loads((SOURCE / "assets/booking/openai.json").read_text())["ambience"]["gain"])
                recovery = data["ambience_recovery"]
                self.assertEqual(recovery["original_report_sha256"], data["caption_source"]["report_sha256"])
                self.assertEqual(recovery["noise_pcm_sha256"], data["ambience"]["pcm_sha256"])
                self.assertEqual(recovery["verification"], data["input_integrity"])
                self.assertEqual(data["input_integrity"]["verified_clips"], 6)
                self.assertFalse(data["passed"])
                self.assertEqual(data["metrics"]["workflow_checks_passed"], 7)
                self.assertEqual(data["metrics"]["new_bookings"], 0)
                self.assertEqual(data["metrics"]["simulated_reminders"], 0)
        self.assertEqual(recordings[0]["provider_options"], recordings[1]["provider_options"])
        self.assertTrue(recordings[0]["source_working_tree_changes"])
        self.assertIn("source_revision_base", recordings[1])
        self.assertNotIn('Gemini 3.8 Live · reminder incomplete', article)

    def test_static_booking_players_use_the_new_audio_and_audio_timed_transcripts(self):
        article = (SOURCE / "content/keep-talking-while-we-book-it.html").read_text()
        for condition, prefix in [("clean", "clean/"), ("cafe", "")]:
            data = json.loads((SOURCE / f"assets/booking/{prefix}openai.json").read_text())
            self.assertIn(f'assets/booking/{prefix}openai.mp3?v={data["audio_sha256"][:12]}', article)
            block = re.search(f'<!-- booking-transcript:{condition}:start -->(.*?)<!-- booking-transcript:{condition}:end -->', article, re.S).group(1)
            rows = re.findall(r'<li class="replay-caption-row"><span>[^<]+</span><strong>[^<]+</strong><span>(.*?)</span></li>', block)
            self.assertEqual([unescape(text) for text in rows], [c["text"] for c in data["captions"]])

    def test_player_script_url_changes_when_its_contents_change(self):
        source = Path(self.temp.name) / "source"
        shutil.copytree(SOURCE, source, ignore=shutil.ignore_patterns("_site", "__pycache__"))
        player = source / "assets/booking-replay.js"
        style = source / "assets/booking-replay.css"
        versions = []
        with patch("build.SOURCE", source):
            for prefix in ("/", "/parlora/"):
                version = hashlib.sha256(player.read_bytes()).hexdigest()[:12]
                style_version = hashlib.sha256(style.read_bytes()).hexdigest()[:12]
                build(self.output, prefix)
                article = (self.output / "blog/keep-talking-while-we-book-it/index.html").read_text()
                self.assertIn(f'src="{prefix}assets/booking-replay.js?v={version}"', article)
                self.assertIn(f'href="{prefix}assets/booking-replay.css?v={style_version}"', article)
                if versions:
                    self.assertNotIn(f'booking-replay.js?v={versions[-1]}"', article)
                versions.append(version)
                player.write_text(player.read_text() + "\n// Updated player build\n")
                style.write_text(style.read_text() + "\n/* Updated style build */\n")
        self.assertNotEqual(*versions)

    def test_github_pages_subpath_and_shared_analytics_property(self):
        build(self.output, "/parlora/", analytics=True)
        self.assertEqual(verify(self.output, "/parlora/", analytics=True), 6)
        self.assertIn('href="/parlora/blog/introducing-parlora/"', (self.output / "index.html").read_text())
        # A production build cannot silently become a local preview.
        with self.assertRaisesRegex(ValueError, "analytics beacon count"):
            verify(self.output, "/parlora/")
        # Rebuilding a preview removes the production beacon and stale pages.
        (self.output / "stale.html").write_text("Old page")
        build(self.output)
        self.assertFalse((self.output / "stale.html").exists())

    def test_build_does_not_replace_unrelated_files_or_source_directory(self):
        self.output.mkdir()
        keep = self.output / "keep.txt"
        keep.write_text("Not generated by Parlora")
        with self.assertRaisesRegex(ValueError, "Refusing to replace"):
            build(self.output)
        self.assertEqual(keep.read_text(), "Not generated by Parlora")
        with self.assertRaisesRegex(ValueError, "must not contain"):
            build(SOURCE)

    def test_articles_load_required_grammars_before_the_highlighter(self):
        build(self.output, "/parlora/")
        article = (self.output / "blog/observability-in-parlora/index.html").read_text()
        scripts = ["prism-core.min.js", "prism-elixir.min.js", "prism-bash.min.js", "site.js"]
        positions = [article.index(f'src="/parlora/assets/{"" if name == "site.js" else "vendor/"}{name}"')
                     for name in scripts]
        self.assertEqual(positions, sorted(positions))
        for name in scripts:
            self.assertEqual(article.count(name), 1)
        introduction = (self.output / "blog/introducing-parlora/index.html").read_text()
        self.assertIn("prism-elixir.min.js", introduction)
        self.assertNotIn("prism-bash.min.js", introduction)
        self.assertNotIn("prism-core.min.js", (self.output / "index.html").read_text())

    def test_sharing_metadata_and_images_in_preview_and_production(self):
        for prefix in ("/", "/parlora/"):
            with self.subTest(prefix=prefix):
                build(self.output, prefix)
                home = Page((self.output / "index.html").read_text())
                article_path = self.output / "blog/introducing-parlora/index.html"
                article = Page(article_path.read_text())
                self.assertEqual(home.meta["og:image"], "https://hfiguera.github.io/parlora/assets/social/parlora.png")
                self.assertEqual(article.meta["og:image"], "https://hfiguera.github.io/parlora/assets/social/introducing-parlora.png")
                self.assertEqual(article.meta["og:title"], "Introducing Parlora: build voice AI agents with Elixir | Parlora")
                for page in (home, article):
                    self.assertEqual(page.meta["twitter:card"], "summary_large_image")
                    self.assertEqual(page.meta["twitter:image"], page.meta["og:image"])
                    self.assertEqual(page.meta["twitter:image:alt"], page.meta["og:image:alt"])
                    self.assertEqual(page.meta["og:image:width"], "1200")
                    self.assertEqual(page.meta["og:image:height"], "630")
                self.assertFalse((self.output / "social/render.py").exists())
                self.assertNotIn("{{", article_path.read_text())

    def test_articles_without_custom_artwork_use_the_site_image(self):
        source = Path(self.temp.name) / "source"
        shutil.copytree(SOURCE, source, ignore=shutil.ignore_patterns("_site", "__pycache__"))
        config = json.loads((source / "site.json").read_text())
        introduction = next(a for a in config["articles"] if a["slug"] == "introducing-parlora")
        del introduction["social_image"]
        (source / "site.json").write_text(json.dumps(config))
        with patch("build.SOURCE", source):
            build(self.output)
            verify(self.output)
        article = (self.output / "blog/introducing-parlora/index.html").read_text()
        self.assertEqual(Page(article).meta["og:image"], "https://hfiguera.github.io/parlora/assets/social/parlora.png")
        self.assertIn('"image": "https://hfiguera.github.io/parlora/assets/social/parlora.png"', article)

    def test_verification_rejects_broken_sharing_metadata_or_images(self):
        build(self.output)
        article = self.output / "blog/introducing-parlora/index.html"
        original = article.read_text()
        article.write_text(original.replace('name="twitter:image"', 'name="missing:image"'))
        with self.assertRaisesRegex(ValueError, "sharing metadata twitter:image"):
            verify(self.output)
        article.write_text(original)
        image = self.output / "assets/social/introducing-parlora.png"
        original_png = image.read_bytes()
        image.write_bytes(b"not a PNG")
        with self.assertRaisesRegex(ValueError, "Expected a PNG"):
            verify(self.output)
        # The metadata must describe the real file, not a hardcoded size.
        image.write_bytes(original_png[:16] + b"\x00\x00\x00\x01" + original_png[20:])
        with self.assertRaisesRegex(ValueError, "1200x630 PNG"):
            verify(self.output)
        image.unlink()
        with self.assertRaisesRegex(ValueError, "Missing sharing image"):
            verify(self.output)


if __name__ == "__main__":
    unittest.main()

class ReadingTimeTest(unittest.TestCase):
    def test_optional_audio_transcripts_do_not_inflate_article_reading_time(self):
        from build import reading_minutes
        self.assertEqual(reading_minutes('<p>Article.</p><ol data-replay-transcript>' + 'caption '*5000 + '</ol>'), '1')
        self.assertEqual(reading_minutes('<ol><li>'+'narrative '*401+'</li></ol>'), '3')
