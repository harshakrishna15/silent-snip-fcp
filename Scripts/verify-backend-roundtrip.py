#!/usr/bin/env python3
"""Compare a generated project with a real Final Cut XML re-export.

Developer verification only. Never opens Final Cut or modifies either project.
Returns nonzero when imported cut structure or saved effect payload differs.
"""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def inventory(path):
    if path.suffix.lower() == ".fcpxmld":
        path = path / "Info.fcpxml"
    document = ET.parse(path)
    resources = {node.attrib["id"]: node for node in document.findall("./resources/*")}
    projects = document.findall(".//project")
    if len(projects) != 1:
        raise ValueError("Expected exactly one project")
    project = projects[0]
    sequence = project.find("sequence")
    rational = lambda value: Fraction((value or "0s").removesuffix("s"))
    origin = rational(sequence.get("tcStart"))
    clips = []
    payloads = []
    for clip in sequence.findall("spine/asset-clip"):
        asset = resources[clip.get("ref")]
        effects = clip.findall("filter-audio")
        clips.append({
            "offset": str(rational(clip.get("offset")) - origin),
            "sourceStart": str(rational(clip.get("start"))),
            "duration": str(rational(clip.get("duration"))),
            "media": asset.find("media-rep").get("src"),
            "audioOnly": asset.get("hasVideo", "0") == "0" or clip.get("srcEnable") == "audio",
            "effectUIDs": [resources[effect.get("ref")].get("uid") for effect in effects],
        })
        payloads.append([{
            "parameters": sorted((p.get("key"), p.get("value")) for p in effect.findall("param")),
            "savedData": sorted((p.get("key"), "".join((p.text or "").split())) for p in effect.findall("data")),
        } for effect in effects])
    return {
        "project": project.get("name"),
        "projectUID": project.get("uid"),
        "duration": str(rational(sequence.get("duration"))),
        "clips": clips,
    }, payloads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("generated", type=Path)
    parser.add_argument("roundtrip", type=Path)
    args = parser.parse_args()
    expected, expected_payload = inventory(args.generated)
    actual, actual_payload = inventory(args.roundtrip)
    # Final Cut assigns fresh project/event UUIDs when importing XML.
    structure_matches = all(expected[key] == actual[key] for key in ("project", "duration", "clips"))
    payload_matches = expected_payload == actual_payload
    print(json.dumps({
        "cutStructureVerified": structure_matches,
        "effectPayloadUnchanged": payload_matches,
        "effectPayloadNote": "Changed serialization requires a separate semantic settings check; missing values must not be treated as preserved.",
        "generatedProjectUID": expected["projectUID"],
        "importedProject": actual,
        "effectTriggered": False,
        "classifiesBreaths": False,
    }, indent=2))
    return 0 if structure_matches and payload_matches else 1


if __name__ == "__main__":
    raise SystemExit(main())
