"""Generate isolated FCP import fixtures referencing generated local media."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

DEFAULT_FOLDER = Path(__file__).resolve().parent.parent / "build" / "Fixtures"


def make_project(folder, name, *, context=False, repeated=False):
    root = ET.Element("fcpxml", version="1.14")
    resources = ET.SubElement(root, "resources")
    ET.SubElement(resources, "format", id="r1", frameDuration="1/30s", width="640", height="360", colorSpace="1-1-1 (Rec. 709)")
    for identifier, filename, duration, channels in (
        ("r2", "Recording.wav", "10s", "2"),
        ("r3", "OtherDialogue.wav", "7/10s", "1"),
        ("r4", "Music.wav", "10s", "1"),
    ):
        attrs = dict(id=identifier, name=filename, start="0s", duration=duration, hasAudio="1", audioSources="1", audioChannels=channels, audioRate="48000")
        asset = ET.SubElement(resources, "asset", attrs)
        ET.SubElement(asset, "media-rep", kind="original-media", src=(folder / filename).as_uri())
    event = ET.SubElement(root, "event", name="Cutdown Integration Fixtures")
    project = ET.SubElement(event, "project", name=name)
    sequence = ET.SubElement(project, "sequence", format="r1", duration="16s" if repeated else "10s", tcStart="0s", tcFormat="NDF", audioLayout="stereo", audioRate="48k")
    spine = ET.SubElement(sequence, "spine")
    target = ET.SubElement(
        spine, "asset-clip", ref="r2", name="Audio recording",
        offset="0s", start="1s" if repeated else "0s", duration="8s" if repeated else "10s", audioRole="dialogue"
    )
    if context:
        ET.SubElement(target, "asset-clip", ref="r3", name="Other dialogue", lane="-1", offset="12/5s", start="0s", duration="7/10s", audioRole="dialogue")
        ET.SubElement(target, "asset-clip", ref="r4", name="Music", lane="-2", offset="0s", start="0s", duration="10s", audioRole="music")
    ET.SubElement(target, "marker", start="4s", duration="1/30s", value="User marker — keep")
    if repeated:
        # Both clips deliberately share a source, name, trim and duration. Only
        # their timeline occurrences distinguish which one carries the effect.
        ET.SubElement(spine, "asset-clip", ref="r2", name="Audio recording", offset="8s", start="1s", duration="8s", audioRole="dialogue")
    destination = folder / (name + ".fcpxmld")
    destination.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(destination / "Info.fcpxml", encoding="utf-8", xml_declaration=True)
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio-only", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_FOLDER)
    args = parser.parse_args()
    folder = args.output_dir.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    make_project(folder, "Cutdown Audio Only Basic")
    make_project(folder, "Cutdown Audio Only Trimmed Repeated", repeated=True)
    make_project(folder, "Cutdown Audio Only Dialogue Context", context=True)
    expectations = {
        "settings": {"thresholdDBFS": -40, "minimumSilenceDuration": 0.5, "beforeSpeechPadding": 0.1, "afterSpeechPadding": 0.1},
        "timeUnit": "seconds from the beginning of the project; end-exclusive intervals",
        "projects": [
            {"name": "Cutdown Audio Only Basic", "targetRange": [0, 10], "sourceRange": [0, 10], "expectedCuts": [[2.1, 3.4], [5.1, 6.9]], "remainingTargetDuration": 6.9, "userMarkerBeforeCuts": 4},
            {"name": "Cutdown Audio Only Trimmed Repeated", "targetRange": [0, 8], "sourceRange": [1, 9], "expectedCuts": [[1.1, 2.4], [4.1, 5.9]], "remainingTargetDuration": 4.9, "userMarkerBeforeCuts": 3},
            {"name": "Cutdown Audio Only Trimmed Repeated", "targetRange": [8, 16], "sourceRange": [1, 9], "expectedCuts": [[9.1, 10.4], [12.1, 13.9]], "remainingTargetDuration": 4.9, "userMarkerBeforeCuts": 3},
            {"name": "Cutdown Audio Only Dialogue Context", "targetRange": [0, 10], "sourceRange": [0, 10], "expectedCuts": [[5.1, 6.9]], "remainingTargetDuration": 8.2, "userMarkerBeforeCuts": 4},
        ],
        "notes": [
            "Each expectation starts from a fresh, unmodified project.",
            "The context project has Dialogue at 2.4–3.1 seconds and separate Music across the entire project.",
            "The first silence splits into two 0.4-second intervals, both below the 0.5-second minimum.",
            "Audio-only clips have original PCM media and no video source. The project still has a 30 fps timeline clock.",
            "These files are import fixtures. Live Final Cut effect compatibility requires separate verification.",
        ],
    }
    (folder / "Audio Expected Results.json").write_text(json.dumps(expectations, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
