"""Verify generated PCM samples, expected edits, and Final Cut's installed DTD."""
import argparse
from array import array
from fractions import Fraction
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlparse
import wave
import xml.etree.ElementTree as ET

FOLDER = Path(__file__).resolve().parent.parent / "build" / "Fixtures"
DTD = Path("/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd")
RATE = 48_000


def read_pcm(folder, name, frames, channels):
    with wave.open(str(folder / name), "rb") as source:
        assert source.getcomptype() == "NONE", name
        assert source.getsampwidth() == 2, name
        assert source.getframerate() == RATE, name
        assert source.getnchannels() == channels, name
        assert source.getnframes() == frames, name
        samples = array("h", source.readframes(frames))
    if sys.byteorder != "little":
        samples.byteswap()
    assert len(samples) == frames * channels, name
    return samples


def levels(samples, channels):
    """Per-window maximum channel RMS; 480 samples are exactly 10 ms."""
    result = []
    for start in range(0, len(samples), 480 * channels):
        window = samples[start:start + 480 * channels]
        result.append(max(
            (sum(value * value for value in window[channel::channels]) / (len(window) // channels)) ** 0.5 / 32768
            for channel in range(channels)
        ))
    return result


def measured_cuts(window_levels, start_second, end_second):
    # The fixture expectation is expressed in exact project frames, independent
    # of media timestamps or floating-point seconds used by a player.
    first, limit = start_second * 100, end_second * 100
    runs = []
    start = None
    for index in range(first, limit + 1):
        quiet = index < limit and window_levels[index] < 0.01
        if quiet and start is None:
            start = index
        if not quiet and start is not None:
            if index - start >= 50:
                lower = Fraction(start + 10, 100) * 30
                upper = Fraction(index - 10, 100) * 30
                lower_frame = -(-lower.numerator // lower.denominator)
                upper_frame = upper.numerator // upper.denominator
                if upper_frame > lower_frame:
                    runs.append([float(Fraction(lower_frame, 30)), float(Fraction(upper_frame, 30))])
            start = None
    return runs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dtd", type=Path, default=DTD)
    parser.add_argument("--folder", type=Path, default=FOLDER)
    args = parser.parse_args()
    folder = args.folder.resolve()
    assert args.dtd.is_file(), f"Install Final Cut Pro, or provide --dtd: {args.dtd}"

    recording = read_pcm(folder, "Recording.wav", 10 * RATE, 2)
    other = read_pcm(folder, "OtherDialogue.wav", int(0.7 * RATE), 1)
    music = read_pcm(folder, "Music.wav", 10 * RATE, 1)
    for start, end in ((2 * RATE, 7 * RATE // 2), (5 * RATE, 7 * RATE)):
        assert all(value == 0 for value in recording[start * 2:end * 2]), "Known pause must contain only PCM zeros."
        assert any(value != 0 for value in music[start:end]), "Music must continue through the known pause."
    original_levels = levels(recording, 2)
    assert all(level > 0.05 for level in original_levels[:200]), "Known audible section is missing."

    trimmed = recording[RATE * 2:9 * RATE * 2] * 2
    trimmed_levels = levels(trimmed, 2)
    context = array("h", recording)
    for index, value in enumerate(other):
        for channel in range(2):
            position = (12 * RATE // 5 + index) * 2 + channel
            context[position] += value
    context_levels = levels(context, 2)
    manifest = json.loads((folder / "Audio Expected Results.json").read_text())
    verified_xml = set()
    for expected in manifest["projects"]:
        project = expected["name"]
        selected_levels = trimmed_levels if "Trimmed" in project else context_levels if "Context" in project else original_levels
        measured = measured_cuts(selected_levels, *expected["targetRange"])
        assert measured == expected["expectedCuts"], (project, measured, expected["expectedCuts"])
        xml_path = folder / (project + ".fcpxmld") / "Info.fcpxml"
        root = ET.parse(xml_path).getroot()
        asset = root.find("./resources/asset[@id='r2']")
        assert asset is not None and asset.get("hasAudio") == "1" and asset.get("hasVideo", "0") == "0"
        assert asset.find("media-rep").get("kind") == "original-media"
        for media in root.findall("./resources/asset/media-rep"):
            parsed = urlparse(media.get("src"))
            assert parsed.scheme == "file" and Path(unquote(parsed.path)).is_file(), media.attrib
        sequence = root.find("./event/project/sequence")
        clips = sequence.findall("./spine/asset-clip")
        matches = [clip for clip in clips if Fraction(clip.get("offset").removesuffix("s")) == expected["targetRange"][0]]
        assert len(matches) == 1
        clip = matches[0]
        assert Fraction(clip.get("start").removesuffix("s")) == expected["sourceRange"][0]
        assert Fraction(clip.get("duration").removesuffix("s")) == expected["targetRange"][1] - expected["targetRange"][0]
        print(f"PASS {project}, target {expected['targetRange']}: {measured}")
        verified_xml.add(xml_path)
    for xml_path in sorted(verified_xml):
        # libxml interprets this argument as a URI; encode the spaces in the
        # installed application's name instead of handing it a raw path.
        subprocess.run(["xmllint", "--noout", "--dtdvalid", args.dtd.resolve().as_uri(), str(xml_path)], check=True)
        print(f"DTD PASS {xml_path.parent.name}")


if __name__ == "__main__":
    main()
