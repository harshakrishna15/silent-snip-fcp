"""Native-audio comparison contracts using tiny, lossless synthetic WAVs."""
from fractions import Fraction
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "Scripts/compare-processed-audio.py"
SPEC = importlib.util.spec_from_file_location("compare_processed_audio", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def rational(value):
    value = Fraction(value)
    return {"numerator": value.numerator, "denominator": value.denominator}


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg and ffprobe required")
class ProcessedAudioComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="processed audio proof ")
        self.root = Path(self.temporary.name)
        self.rate = 48_000
        self.frames = [(100 + i, -500 - i) for i in range(120)]
        self.original = self.wav("original.wav", self.frames)
        self.kept = self.frames[:30] + self.frames[50:80] + self.frames[90:]
        self.cleaned = self.wav("cleaned.wav", self.kept)
        self.report = {"insertedGapDuration": rational(0),
                       "originalProjectDuration": rational(Fraction(120, self.rate)),
                       "resultProjectDuration": rational(Fraction(90, self.rate)),
                       "selectedRanges": [{"start": rational(Fraction(a, self.rate)),
                                           "end": rational(Fraction(b, self.rate))} for a, b in [(30, 50), (80, 90)]]}
        self.edit_report = self.root / "Edit-Report.json"

    def tearDown(self):
        self.temporary.cleanup()

    def wav(self, name, frames, rate=None, channels=2):
        path = self.root / name
        with wave.open(str(path), "wb") as output:
            output.setnchannels(channels)
            output.setsampwidth(2)
            output.setframerate(rate or self.rate)
            output.writeframes(b"".join(struct.pack("<" + "h" * channels, *frame) for frame in frames))
        return path

    def compare(self, **kwargs):
        self.edit_report.write_text(json.dumps(self.report))
        return MODULE.compare(self.original, self.cleaned, self.edit_report, **kwargs)

    def test_exact_cuts_keep_project_lead_in_and_trailing_neighbor(self):
        result = self.compare(repeated_original=self.original)
        self.assertTrue(result["passes"])
        self.assertTrue(result["pcmIdentical"])
        self.assertTrue(result["originalDeterminismVerified"])
        self.assertEqual(result["originalFrames"], 120)
        self.assertEqual(result["actualCleanedFrames"], 90)
        self.assertEqual(result["expectedCleanedPCM_SHA256"], result["cleanedPCM_SHA256"])
        self.assertEqual([b["resultFrame"] for b in result["cutBoundaries"]], [30, 60])

    def test_one_sample_change_at_join_is_not_hidden(self):
        frames = list(self.kept)
        frames[30] = (frames[30][0], frames[30][1] + 1)
        self.cleaned = self.wav("changed.wav", frames)
        result = self.compare()
        self.assertFalse(result["passes"])
        difference = result["firstDifference"]
        self.assertEqual((difference["resultFrame"], difference["originalFrame"], difference["channel"]), (30, 50, 1))
        self.assertEqual(difference["framesFromBoundary"], 0)

    def test_cleaned_short_or_extra_frames_fail(self):
        for frames, kind in [(self.kept[:-1], "missingCleanedFrame"), (self.kept + [(0, 0)], "extraCleanedFrame")]:
            with self.subTest(kind=kind):
                self.cleaned = self.wav("length.wav", frames)
                result = self.compare()
                self.assertFalse(result["pcmIdentical"])
                self.assertEqual(result["firstDifference"]["kind"], kind)

    def test_nondeterminism_inside_removed_audio_still_fails_repeat_check(self):
        frames = list(self.frames)
        frames[40] = (1, 2)
        repeated = self.wav("repeat.wav", frames)
        result = self.compare(repeated_original=repeated)
        self.assertTrue(result["pcmIdentical"])
        self.assertFalse(result["passes"])
        self.assertFalse(result["originalDeterminismVerified"])
        self.assertEqual(result["originalRepeat"]["firstDifference"]["originalFrame"], 40)
        self.assertEqual(result["originalRepeat"]["firstDifference"]["originalSeconds"], 40 / self.rate)

    def test_repeat_frame_counts_must_match_even_when_retained_audio_is_equal(self):
        for frames in [self.frames[:-1], self.frames + [(0, 0)]]:
            with self.subTest(frames=len(frames)):
                repeated = self.wav("repeat-length.wav", frames)
                with self.assertRaises(MODULE.ComparisonError):
                    self.compare(repeated_original=repeated)

    def test_unedited_project_is_compared_in_full(self):
        self.cleaned = self.original
        self.report.update(selectedRanges=[], resultProjectDuration=rational(Fraction(120, self.rate)))
        result = self.compare()
        self.assertTrue(result["passes"])
        self.assertEqual(result["cutBoundaries"], [])
        self.assertFalse(result["originalDeterminismVerified"])

    def test_original_frame_count_is_required(self):
        for frames in [self.frames[:-1], self.frames + [(0, 0)]]:
            with self.subTest(frames=len(frames)):
                self.original = self.wav("bad-original.wav", frames)
                with self.assertRaises(MODULE.ComparisonError):
                    self.compare()

    def test_rejects_gaps_and_fractional_sample_boundaries(self):
        self.report["insertedGapDuration"] = rational(1)
        with self.assertRaisesRegex(MODULE.ComparisonError, "gaps"):
            self.compare()
        self.report["insertedGapDuration"] = rational(0)
        self.report["selectedRanges"][0]["start"] = rational(Fraction(61, 2 * self.rate))
        with self.assertRaisesRegex(MODULE.ComparisonError, "sample boundary"):
            self.compare()

    def test_rejects_rate_and_channel_changes(self):
        self.cleaned = self.wav("rate.wav", self.kept, rate=44_100)
        with self.assertRaisesRegex(MODULE.ComparisonError, "sample rate/channel"):
            self.compare()
        self.cleaned = self.wav("mono.wav", [(f[0],) for f in self.kept], channels=1)
        with self.assertRaisesRegex(MODULE.ComparisonError, "sample rate/channel"):
            self.compare()

    def transcode(self, source, name, codec):
        output = self.root / name
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(source),
                        "-c:a", codec, str(output)], check=True, capture_output=True)
        return output

    def test_exactly_representable_24_bit_and_float32_pcm_are_supported(self):
        original, cleaned = self.original, self.cleaned
        for codec in ("pcm_s24le", "pcm_f32le"):
            with self.subTest(codec=codec):
                self.original = self.transcode(original, codec + "-original.wav", codec)
                self.cleaned = self.transcode(cleaned, codec + "-cleaned.wav", codec)
                result = self.compare(repeated_original=self.original)
                self.assertTrue(result["passes"])
                self.assertEqual(result["format"]["codec"], codec)

    def test_rejects_32_bit_integer_changes_that_alias_when_decoded_to_float32(self):
        for name, value in (("original32", 0x40000000), ("cleaned32", 0x40000001)):
            path = self.root / (name + ".wav")
            with wave.open(str(path), "wb") as output:
                output.setparams((1, 4, self.rate, 0, "NONE", "not compressed"))
                output.writeframes(struct.pack("<i", value) * 120)
        self.original, self.cleaned = self.root / "original32.wav", self.root / "cleaned32.wav"
        self.report.update(selectedRanges=[], resultProjectDuration=rational(Fraction(120, self.rate)))
        # These distinct 32-bit samples both become 0.5 in Float32. Reject the
        # precision rather than let an equality report hide the one-bit change.
        with self.assertRaisesRegex(MODULE.ComparisonError, "precision/codec"):
            self.compare()

    def test_rejects_float64_and_lossy_inputs_before_comparison(self):
        for name, codec, message in (("wide.wav", "pcm_f64le", "precision/codec"),
                                     ("lossy.mp3", "libmp3lame", "PCM WAV"),
                                     ("lossy.wav", "adpcm_ima_wav", "precision/codec")):
            with self.subTest(codec=codec):
                original = self.original
                self.original = self.transcode(original, name, codec)
                with self.assertRaisesRegex(MODULE.ComparisonError, message):
                    self.compare()
                self.original = original

    def test_original_cleaned_and_repeat_require_same_declared_pcm_format(self):
        self.cleaned = self.transcode(self.cleaned, "different-precision.wav", "pcm_s24le")
        with self.assertRaisesRegex(MODULE.ComparisonError, "PCM format"):
            self.compare()
        self.cleaned = self.wav("cleaned16.wav", self.kept)
        repeated = self.transcode(self.original, "repeat24.wav", "pcm_s24le")
        with self.assertRaisesRegex(MODULE.ComparisonError, "PCM format"):
            self.compare(repeated_original=repeated)

    def test_explicit_nonzero_origin_normalizes_cuts_without_losing_lead_in(self):
        self.report["originalProjectRange"] = {"start": rational(3600),
                                               "end": rational(Fraction(3600) + Fraction(120, self.rate))}
        for item in self.report["selectedRanges"]:
            for field in ("start", "end"):
                value = item[field]
                item[field] = rational(Fraction(value["numerator"], value["denominator"]) + 3600)
        self.assertTrue(self.compare()["pcmIdentical"])

    def test_rejects_overlapping_or_inconsistent_report(self):
        self.report["selectedRanges"][1]["start"] = rational(Fraction(40, self.rate))
        with self.assertRaisesRegex(MODULE.ComparisonError, "nonoverlapping"):
            self.compare()
        self.report["selectedRanges"] = []
        with self.assertRaisesRegex(MODULE.ComparisonError, "Result duration"):
            self.compare()

    def test_streaming_handles_multiple_blocks(self):
        frames = [(i % 20_000, -(i % 20_000)) for i in range(MODULE.BLOCK_FRAMES * 3 + 7)]
        self.original = self.wav("large.wav", frames)
        start, end = MODULE.BLOCK_FRAMES - 3, MODULE.BLOCK_FRAMES + 5
        self.cleaned = self.wav("large-cleaned.wav", frames[:start] + frames[end:])
        self.report.update(originalProjectDuration=rational(Fraction(len(frames), self.rate)),
                           resultProjectDuration=rational(Fraction(len(frames) - (end - start), self.rate)),
                           selectedRanges=[{"start": rational(Fraction(start, self.rate)), "end": rational(Fraction(end, self.rate))}])
        self.assertTrue(self.compare()["passes"])

    def test_cli_records_invalid_input_and_never_overwrites_source(self):
        self.edit_report.write_text(json.dumps(self.report))
        original_bytes = self.original.read_bytes()
        command = [sys.executable, str(SCRIPT), "--original", str(self.original), "--cleaned", str(self.cleaned),
                   "--edit-report", str(self.edit_report), "--output", str(self.original)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.original.read_bytes(), original_bytes)
        output = self.root / "comparison.json"
        command[-1] = str(output)
        self.report["insertedGapDuration"] = rational(1)
        self.edit_report.write_text(json.dumps(self.report))
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(json.loads(output.read_text())["valid"])


if __name__ == "__main__":
    unittest.main()
