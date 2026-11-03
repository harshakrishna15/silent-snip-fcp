import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
import wave
import xml.etree.ElementTree as ET


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("throughput_fixtures", REPO / "Scripts/make-throughput-fixtures.py")
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)


class ThroughputFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.workspace = Path(self.temp.name).resolve() / "Workspace With Spaces"
        self.build = self.workspace / "build"
        self.build.mkdir(parents=True)
        self.library = self.workspace / "Cutdown Integration.fcpbundle"
        self.library.mkdir()
        self.source = self.build / "Generated Narration.wav"
        with wave.open(str(self.source), "wb") as audio:
            audio.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
            audio.writeframes(b"\x00\x10\x00\x00" * 2400)
        self.template = self.build / "Native Effects.fcpxml"
        root = ET.Element("fcpxml", version="1.14")
        resources = ET.SubElement(root, "resources")
        library = ET.SubElement(root, "library", location=self.library.as_uri())
        event = ET.SubElement(library, "event", name="Disposable Native Template")
        project = ET.SubElement(event, "project", name="Disposable Native Template")
        sequence = ET.SubElement(project, "sequence")
        spine = ET.SubElement(sequence, "spine")
        clip = ET.SubElement(spine, "asset-clip")
        for role, uid in FIXTURES.EFFECT_UIDS.items():
            ET.SubElement(resources, "effect", id=role, uid=uid, name=role)
            effect = ET.SubElement(clip, "filter-audio", ref=role, name=role)
            if role == "silentsnip":
                ET.SubElement(effect, "data", key="effectState").text = "opaque archived state retained byte-for-byte"
        ET.ElementTree(root).write(self.template, encoding="utf-8")
        self.output = self.build / "New Throughput Fixtures"
        self.commands = []
        self.frames_by_path = {}
        self.bad_probe = False

    def run_tool(self, command, **kwargs):
        """Stub codec I/O; actual ALAC generation is a separate integration check."""
        self.commands.append(command)
        target = Path(command[-1])
        if command[0] == "ffmpeg":
            self.assertIn("-n", command)
            self.assertIn("-stream_loop", command)
            self.assertEqual(command[command.index("-stream_loop") + 1], "-1")
            seconds = int(command[command.index("-t") + 1])
            self.assertFalse(target.exists())
            target.write_bytes(f"stub-generated-alac-{seconds}".encode())
            self.frames_by_path[target] = seconds * 48000
            return SimpleNamespace(returncode=0)
        self.assertEqual(command[0], "ffprobe")
        self.assertTrue(kwargs["capture_output"])
        return SimpleNamespace(stdout=json.dumps({"streams": [{"codec_name": "alac", "sample_rate": "48000", "channels": 1,
            "duration_ts": self.frames_by_path[target] - int(self.bad_probe), "time_base": "1/48000"}]}))

    def generate(self, durations=(60, 300, 3600)):
        return FIXTURES.create_fixtures(self.output, self.source, self.template, durations,
                                        workspace=self.workspace, runner=self.run_tool)

    def test_six_projects_reference_three_lossless_sources_and_preserve_effect_payloads(self):
        source_before = self.source.read_bytes()
        template_before = self.template.read_bytes()
        manifest = self.generate()
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(self.template.read_bytes(), template_before)
        root = ET.parse(manifest["fcpxml"]).getroot()
        self.assertEqual(root.find("library").get("location"), self.library.as_uri())
        events = root.findall("./library/event")
        self.assertEqual(len(events), 1)
        self.assertEqual(len(events[0].findall("project")), 6)
        resources = {node.get("id"): node for node in root.findall("./resources/effect")}
        for item, project in zip(manifest["projects"], events[0].findall("project")):
            self.assertEqual(project.get("name"), item["name"])
            self.assertTrue(item["name"].startswith("Disposable Throughput "))
            sequence = project.find("sequence")
            self.assertEqual(sequence.get("tcStart"), "3600s")
            self.assertEqual(sequence.get("audioRate"), "48k")
            self.assertEqual(sequence.get("audioLayout"), "stereo")
            clips = sequence.findall("spine/asset-clip")
            self.assertEqual(len(clips), 1)
            self.assertEqual(clips[0].get("name"), item["clipName"])
            self.assertEqual(clips[0].get("audioRole"), "dialogue")
            filters = clips[0].findall("filter-audio")
            self.assertEqual([resources[node.get("ref")].get("uid") for node in filters], item["effects"])
            self.assertEqual(filters[-1].find("data").text, "opaque archived state retained byte-for-byte")
            self.assertEqual(item["targetSeconds"], item["durationSeconds"] / 60)
        assets = root.findall("./resources/asset")
        self.assertEqual(len(assets), 3)
        for asset, media in zip(assets, manifest["media"]):
            self.assertEqual(asset.find("media-rep").get("src"), Path(media["path"]).as_uri())
            self.assertEqual(asset.find("media-rep").get("kind"), "original-media")
            self.assertEqual(media["codec"], "alac")
            self.assertEqual(media["frames"], media["durationSeconds"] * 48000)
        self.assertEqual(root.find("import-options/option[@key='copy assets']").get("value"), "0")
        self.assertEqual(len({p["uid"] for p in manifest["projects"]}), 6)
        self.assertTrue(any("looped" in note for note in manifest["notes"]))

    def test_refuses_overwrite_without_touching_existing_results(self):
        self.output.mkdir()
        marker = self.output / "Keep.txt"
        marker.write_text("preserve")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.generate()
        self.assertEqual(marker.read_text(), "preserve")
        self.assertEqual(self.commands, [])

    def test_missing_required_library_never_substitutes_another_library(self):
        self.library.rmdir()
        (self.workspace / "Other.fcpbundle").mkdir()
        with self.assertRaisesRegex(ValueError, "Cutdown Integration"):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_rejects_32_bit_source_before_alac_can_discard_low_bits(self):
        # FFmpeg's ALAC encoder reduces 32-bit integer PCM to 24 significant
        # bits. A nominally lossless codec must not conceal that conversion.
        with wave.open(str(self.source), "wb") as audio:
            audio.setparams((1, 4, 48000, 0, "NONE", "not compressed"))
            audio.writeframes(b"\x01\x00\x00\x40" * 2400)
        source_before = self.source.read_bytes()
        template_before = self.template.read_bytes()
        with self.assertRaisesRegex(ValueError, "up to 24 bits"):
            self.generate()
        self.assertEqual(self.commands, [])
        self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(self.template.read_bytes(), template_before)

    def test_rejects_effect_substitution_and_missing_saved_controller_state(self):
        original = self.template.read_text()
        self.template.write_text(original.replace(FIXTURES.EFFECT_UIDS["limiter"], "AudioUnit: unrelated.limiter"))
        with self.assertRaisesRegex(ValueError, "exact Noise Gate"):
            self.generate()
        self.assertFalse(self.output.exists())
        self.template.write_text(original.replace("opaque archived state retained byte-for-byte", ""))
        with self.assertRaisesRegex(ValueError, "effectState archive"):
            self.generate()
        self.assertFalse(self.output.exists())

    def test_rejects_unknown_source_or_template_library(self):
        unknown = self.build / "Personal Recording.wav"
        unknown.write_bytes(self.source.read_bytes())
        with self.assertRaisesRegex(ValueError, "explicitly generated"):
            FIXTURES.create_fixtures(self.output, unknown, self.template, workspace=self.workspace, runner=self.run_tool)
        self.template.write_text(self.template.read_text().replace(self.library.as_uri(), (self.workspace / "Other.fcpbundle").as_uri()))
        with self.assertRaisesRegex(ValueError, "must come from"):
            self.generate()
        self.assertEqual(self.commands, [])

    def test_refuses_duplicate_durations_and_output_outside_build(self):
        with self.assertRaisesRegex(ValueError, "distinct"):
            self.generate((60, 60))
        with self.assertRaisesRegex(ValueError, "build directory"):
            FIXTURES.create_fixtures(self.workspace / "OutsideBuild", self.source, self.template,
                                    workspace=self.workspace, runner=self.run_tool)
        self.assertFalse(self.output.exists())

    def test_rejects_a_codec_output_with_even_one_missing_sample(self):
        self.bad_probe = True
        with self.assertRaisesRegex(ValueError, "exact duration"):
            self.generate((60,))
        self.assertFalse((self.output / "Throughput.fcpxml").exists())
        self.assertFalse((self.output / "Fixture.json").exists())


if __name__ == "__main__":
    unittest.main()
