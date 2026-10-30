"""Create disposable spoken-word fixtures for the required integration library.

Requires macOS say and FFmpeg. Refuses to overwrite an existing fixture folder;
generated source media must remain in place after import into Final Cut.
"""
import argparse
from copy import deepcopy
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import subprocess
import uuid
import wave
import xml.etree.ElementTree as ET


def run(*command):
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--effects-template", type=Path, help="Owned Final Cut XML containing Noise Gate and Limiter")
    args = parser.parse_args()
    workspace = Path(__file__).resolve().parent.parent
    library = workspace / "Cutdown Integration.fcpbundle"
    if not library.is_dir():
        parser.error("Create the workspace Cutdown Integration.fcpbundle first; no other library is permitted.")
    folder = args.output_dir.resolve()
    folder.mkdir(parents=True, exist_ok=False)
    phrases = [
        "This is a disposable voice over recording for Silent Snip.",
        "The cleaned project should keep the original audio effects editable.",
        "The original project and its neighboring clips should stay unchanged.",
    ]
    pcm = bytearray(48000 * 2 // 2)
    for index, phrase in enumerate(phrases):
        aiff = folder / f"Phrase-{index + 1}.aiff"
        wav = folder / f"Phrase-{index + 1}.wav"
        run("/usr/bin/say", "-v", "Daniel", "-r", "170", "-o", str(aiff), phrase)
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(aiff),
            "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(wav))
        with wave.open(str(wav), "rb") as audio:
            frames = audio.readframes(audio.getnframes())
            if not frames or not any(frames):
                raise RuntimeError("macOS speech generation returned empty/silent audio; no import fixture was created")
            pcm.extend(frames)
        pcm.extend(bytes(48000 * 2 * (2 if index < 2 else 1)))
    # One project frame is 1600 samples at 48 kHz / 30 fps.
    pcm.extend(bytes((-len(pcm)) % 3200))
    voice = folder / "Generated Narration.wav"
    with wave.open(str(voice), "wb") as audio:
        audio.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
        audio.writeframes(pcm)
    duration = Fraction(len(pcm) // 2, 48000)
    selected_duration = duration - Fraction(2, 5)
    stamp = uuid.uuid4().hex[:8].upper()
    event_id = str(uuid.uuid4()).upper()
    template = ET.parse(args.effects_template).getroot() if args.effects_template else None
    modes = ["Plain", "Effects"] if template is not None else ["Plain"]
    for mode in modes:
        root = ET.Element("fcpxml", version="1.14")
        options = ET.SubElement(root, "import-options")
        for key, value in [("copy assets", "0"), ("library location", library.as_uri())]:
            ET.SubElement(options, "option", key=key, value=value)
        resources = ET.SubElement(root, "resources")
        ET.SubElement(resources, "format", id="voFormat", frameDuration="1/30s", width="640", height="360", colorSpace="1-1-1 (Rec. 709)")
        asset = ET.SubElement(resources, "asset", id="voAsset", name="Generated Narration", start="0s",
                              duration=f"{duration}s", hasAudio="1", audioSources="1", audioChannels="1", audioRate="48000")
        ET.SubElement(asset, "media-rep", kind="original-media", src=voice.as_uri())
        library_node = ET.SubElement(root, "library", location=library.as_uri())
        event = ET.SubElement(library_node, "event", name=f"Silent Snip Voice-over Milestone {stamp}", uid=event_id)
        name = f"Voice-over Milestone {stamp} {mode}"
        project = ET.SubElement(event, "project", name=name, uid=str(uuid.uuid4()).upper())
        sequence = ET.SubElement(project, "sequence", format="voFormat", duration=f"{selected_duration + 3}s",
                                 tcStart="3600s", tcFormat="NDF", audioLayout="stereo", audioRate="48k")
        spine = ET.SubElement(sequence, "spine")
        ET.SubElement(spine, "gap", name="Disposable lead-in", offset="3600s", start="0s", duration="2s")
        clip = ET.SubElement(spine, "asset-clip", ref="voAsset", name="Generated Narration", offset="3602s",
                             start="1/5s", duration=f"{selected_duration}s", audioRole="dialogue")
        if mode == "Effects":
            for effect in template.findall("./resources/effect"):
                resources.append(deepcopy(effect))
            effects = template.findall(".//spine/asset-clip/filter-audio")
            if not effects:
                parser.error("The supplied template contains no audio effects.")
            for effect in effects:
                clip.append(deepcopy(effect))
        ET.SubElement(spine, "asset-clip", ref="voAsset", name="Disposable neighbor", offset=f"{3602 + selected_duration}s",
                      start="1/5s", duration="1s", audioRole="dialogue")
        path = folder / f"{name}.fcpxml"
        ET.indent(root)
        ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
        print(path)
    (folder / "Fixture.json").write_text(json.dumps({
        "library": str(library), "media": str(voice), "sha256": hashlib.sha256(voice.read_bytes()).hexdigest(),
        "sourceDuration": str(duration), "selectedDuration": str(selected_duration),
        "targetTimelineStart": "2", "targetSourceStart": "1/5", "phrases": phrases,
        "note": "Synthesized speech with deliberate pauses. Reference media in place; preserve after import.",
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
