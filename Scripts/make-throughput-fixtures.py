#!/usr/bin/env python3
"""Create disposable, lossless throughput fixtures in the required FCP library.

The input must be explicitly supplied generated narration under this workspace's
build folder. Existing files are never overwritten. Generated sources must stay
in place after import; this script does not open or edit a Final Cut library.
"""
import argparse
from copy import deepcopy
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from urllib.parse import unquote, urlsplit
import uuid
import wave
import xml.etree.ElementTree as ET


WORKSPACE = Path(__file__).resolve().parent.parent
EFFECT_UIDS = {
    "gate": "AudioUnit: 0x61756678000000b3454d4147",
    "limiter": "Limiter.Levels.audio.effectBundle",
    "silentsnip": "AudioUnit: 0x617566786374646e4374646e",
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def within(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def duration_label(seconds):
    return f"{seconds // 60}m" if seconds % 60 == 0 else f"{seconds}s"


def template_effects(template, library):
    root = ET.parse(template).getroot()
    if root.tag != "fcpxml":
        raise ValueError("The effects template must be FCPXML.")
    libraries = root.findall("./library")
    if len(libraries) != 1:
        raise ValueError("The native effects template must identify its source library.")
    location = urlsplit(libraries[0].get("location", ""))
    if location.scheme != "file" or location.netloc not in ("", "localhost") or Path(unquote(location.path)).resolve() != library:
        raise ValueError("The effects template must come from the workspace Cutdown Integration.fcpbundle.")
    resources = root.findall("./resources/effect")
    by_id = {node.get("id"): node for node in resources}
    if len(by_id) != len(resources) or None in by_id:
        raise ValueError("Effect resource identifiers must be present and unique.")
    matches = []
    for clip in root.findall(".//spine/asset-clip"):
        filters = clip.findall("filter-audio")
        identities = [by_id.get(node.get("ref")) for node in filters]
        uids = [node.get("uid") if node is not None else None for node in identities]
        if len(filters) == 3 and set(uids) == set(EFFECT_UIDS.values()):
            matches.append((clip, filters, identities))
    if len(matches) != 1:
        raise ValueError("Expected exactly one template clip with the exact Noise Gate, Limiter, and Silent Snip effects.")
    clip, filters, identities = matches[0]
    allowed = {"filter-audio", "marker", "chapter-marker", "keyword", "rating", "metadata", "note"}
    if any(node.tag not in allowed for node in clip):
        raise ValueError("Template clip has additional processing; use an isolated static three-effect fixture.")
    if clip.findall(".//keyframeAnimation"):
        raise ValueError("Throughput fixtures require static effect state; automation needs a separate fixture.")
    result = {}
    for effect_filter, resource in zip(filters, identities):
        role = next(role for role, uid in EFFECT_UIDS.items() if resource.get("uid") == uid)
        if effect_filter.get("enabled", "1") != "1":
            raise ValueError("All three template effects must be enabled.")
        result[role] = (deepcopy(resource), deepcopy(effect_filter))
    state = result["silentsnip"][1].findall("data[@key='effectState']")
    if len(state) != 1 or not (state[0].text or "").strip():
        raise ValueError("The native template must include Silent Snip's saved effectState archive.")
    return result


def create_fixtures(output_dir, source, effects_template, durations=(60, 300, 3600), *, workspace=WORKSPACE, runner=None):
    workspace = Path(workspace).resolve()
    build = workspace / "build"
    library_path = workspace / "Cutdown Integration.fcpbundle"
    if library_path.is_symlink() or not library_path.is_dir():
        raise ValueError("Create the workspace Cutdown Integration.fcpbundle as documented; no other library is permitted.")
    library = library_path.resolve()
    source = Path(source).resolve(strict=True)
    template = Path(effects_template).resolve(strict=True)
    output_arg = Path(output_dir)
    if output_arg.exists() or output_arg.is_symlink():
        raise ValueError("Output directory already exists; choose a new fixture folder.")
    output = output_arg.resolve()
    if build.is_symlink() or not within(output, build.resolve()) or output == build.resolve():
        raise ValueError("Place the new fixture folder under this workspace's build directory.")
    if not within(source, build.resolve()) or source.suffix.lower() != ".wav" or not source.name.startswith("Generated "):
        raise ValueError("Supply an explicitly generated WAV source under this workspace's build directory.")
    if not within(template, build.resolve()) or template.suffix.lower() != ".fcpxml":
        raise ValueError("Supply a captured integration FCPXML template under this workspace's build directory.")
    durations = tuple(durations)
    if not durations or any(type(seconds) is not int or not 1 <= seconds <= 86400 for seconds in durations) or len(set(durations)) != len(durations):
        raise ValueError("Durations must be distinct positive integer seconds, no longer than one day.")
    with wave.open(str(source), "rb") as narration:
        if narration.getnframes() == 0 or narration.getnchannels() != 1 or narration.getframerate() != 48000 or narration.getcomptype() != "NONE":
            raise ValueError("Generated narration must be nonempty, mono, 48 kHz PCM WAV.")
        # FFmpeg's ALAC encoder supports at most 24 significant PCM bits.
        # Silently converting 32-bit WAV would discard source precision even
        # though ALAC is a lossless codec at its chosen output bit depth.
        if narration.getsampwidth() not in (1, 2, 3):
            raise ValueError("Generated narration must use integer PCM up to 24 bits for lossless ALAC fixtures.")
        source_frames = narration.getnframes()
    effects = template_effects(template, library)
    source_hash, template_hash = digest(source), digest(template)
    if runner is None:
        for tool in ("ffmpeg", "ffprobe"):
            if shutil.which(tool) is None:
                raise ValueError(f"Required fixture-generation tool is missing: {tool}")
        runner = subprocess.run
    output.mkdir(parents=True, exist_ok=False)
    event_uid = str(uuid.uuid4()).upper()
    event_name = f"Silent Snip Throughput {event_uid[:8]}"
    root = ET.Element("fcpxml", version="1.14")
    options = ET.SubElement(root, "import-options")
    for key, value in (("copy assets", "0"), ("library location", library.as_uri())):
        ET.SubElement(options, "option", key=key, value=value)
    resources = ET.SubElement(root, "resources")
    ET.SubElement(resources, "format", id="throughputFormat", frameDuration="1/30s", width="640", height="360", colorSpace="1-1-1 (Rec. 709)")
    for role, (resource, effect_filter) in effects.items():
        resource.set("id", f"throughput-{role}")
        effect_filter.set("ref", resource.get("id"))
        resources.append(resource)
    library_node = ET.SubElement(root, "library", location=library.as_uri())
    event = ET.SubElement(library_node, "event", name=event_name, uid=event_uid)
    media, projects = [], []
    for seconds in durations:
        label = duration_label(seconds)
        target = output / f"Generated Throughput {label}.m4a"
        runner(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-stream_loop", "-1",
                "-i", str(source), "-t", str(seconds), "-map", "0:a:0", "-vn", "-ar", "48000", "-ac", "1", "-c:a", "alac", str(target)], check=True)
        probe = runner(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                        "stream=codec_name,sample_rate,channels,duration_ts,time_base", "-of", "json", str(target)],
                       check=True, capture_output=True, text=True)
        streams = json.loads(probe.stdout).get("streams", [])
        if len(streams) != 1:
            raise ValueError("Generated fixture does not contain exactly one audio stream.")
        stream = streams[0]
        if stream.get("codec_name") != "alac" or int(stream.get("sample_rate", 0)) != 48000 or stream.get("channels") != 1 or Fraction(stream["time_base"]) * int(stream["duration_ts"]) != seconds:
            raise ValueError("Generated ALAC fixture has an incorrect format or exact duration.")
        asset_id = f"throughput-{seconds}s"
        asset = ET.SubElement(resources, "asset", id=asset_id, name=target.stem, start="0s", duration=f"{seconds}s",
                              hasAudio="1", audioSources="1", audioChannels="1", audioRate="48000")
        ET.SubElement(asset, "media-rep", kind="original-media", src=target.as_uri())
        media.append({"path": str(target), "sha256": digest(target), "durationSeconds": seconds,
                      "frames": seconds * 48000, "codec": "alac", "sampleRate": 48000, "channels": 1})
        for abbreviation, order in (("GL", ("gate", "limiter", "silentsnip")), ("LG", ("limiter", "gate", "silentsnip"))):
            name = f"Disposable Throughput {abbreviation} {label}"
            project_uid = str(uuid.uuid4()).upper()
            project = ET.SubElement(event, "project", name=name, uid=project_uid)
            sequence = ET.SubElement(project, "sequence", format="throughputFormat", duration=f"{seconds}s",
                                     tcStart="3600s", tcFormat="NDF", audioLayout="stereo", audioRate="48k")
            spine = ET.SubElement(sequence, "spine")
            clip = ET.SubElement(spine, "asset-clip", ref=asset_id, name=name, offset="3600s", start="0s",
                                 duration=f"{seconds}s", audioRole="dialogue")
            for role in order:
                clip.append(deepcopy(effects[role][1]))
            projects.append({"name": name, "clipName": name, "uid": project_uid, "durationSeconds": seconds,
                             "targetSeconds": seconds / 60, "effects": [EFFECT_UIDS[role] for role in order],
                             "source": str(target), "sourceStartSeconds": 0, "timelineTimecodeStartSeconds": 3600})
    if digest(source) != source_hash or digest(template) != template_hash:
        raise ValueError("The source or effect template changed during generation.")
    xml = output / "Throughput.fcpxml"
    ET.indent(root)
    ET.ElementTree(root).write(xml, encoding="utf-8", xml_declaration=True)
    manifest = {"version": 1, "createdUTC": datetime.now(timezone.utc).isoformat(), "library": str(library),
                "event": {"name": event_name, "uid": event_uid}, "fcpxml": str(xml),
                "source": {"path": str(source), "sha256": source_hash, "frames": source_frames, "sampleRate": 48000},
                "effectsTemplate": {"path": str(template), "sha256": template_hash}, "media": media, "projects": projects,
                "notes": ["Generated spoken narration is looped to the requested duration; this is a repeatable synthetic throughput fixture, not an hour of diverse speech.",
                          "ALAC source media is lossless, referenced in place, and contains no baked-in gate or limiter. Final Cut applies the preserved native processing effects.",
                          "Compare each order against the same order. Swapping gate and limiter can intentionally change the processed signal.",
                          "Target processing seconds = raw clip audio seconds / 60; include Analyze and fully verified Apply, excluding the user's review time.",
                          "Preserve source media and integration evidence. No library was opened or changed by this generator; do not create optimized or proxy media."]}
    (output / "Fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True, help="New folder under workspace/build; must not exist")
    parser.add_argument("--source", type=Path, required=True, help="Existing generated mono 48 kHz integer PCM narration WAV, up to 24 bits")
    parser.add_argument("--effects-template", type=Path, required=True, help="Native integration FCPXML with the exact three effects and saved Silent Snip state")
    parser.add_argument("--durations", type=int, nargs="+", default=[60, 300, 3600], metavar="SECONDS")
    args = parser.parse_args()
    try:
        manifest = create_fixtures(args.output_dir, args.source, args.effects_template, args.durations)
    except (ValueError, OSError, wave.Error, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    print(manifest["fcpxml"])
    print(str(Path(manifest["fcpxml"]).parent / "Fixture.json"))


if __name__ == "__main__":
    main()
