"""Report verified Analyze + Apply throughput, never detector-only speed.

This is helper processing time. Human review, optional review actions, frontend
notification latency and app startup are excluded and explicitly identified.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def make_report(analysis, apply, verification, receipt, edit, output_xml, raw_seconds):
    if not math.isfinite(raw_seconds) or raw_seconds <= 0:
        raise ValueError("Raw clip duration must be finite and positive")
    request = analysis["request"].upper()
    if apply["request"].upper() != request or receipt["requestID"].upper() != request:
        raise ValueError("Timing and result receipts belong to different requests")
    if analysis["outcome"] != "review" or apply["outcome"] != "verified":
        raise ValueError("Only a completed review and verified Apply can establish throughput")
    if (verification.get("verified") is not True or
            verification.get("sourceMediaVerified") is not True or
            verification.get("differences") != [] or not receipt.get("sourceMedia")):
        raise ValueError("Imported project/effects/source verification did not pass")
    if (verification["expectedProjectUID"] != edit["projectUID"] or
            receipt["expectedSHA256"] != hashlib.sha256(output_xml).hexdigest()):
        raise ValueError("The saved project no longer matches its verification evidence")
    values = [analysis["totalSeconds"], apply["totalSeconds"]]
    if any(isinstance(v, bool) or not isinstance(v, (float, int)) or
           not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("Timing values must be finite and positive")
    total = sum(values)
    # Current goal: approximately three seconds for five minutes of raw audio.
    # This narrower helper metric can disprove that budget, but cannot establish
    # complete button-to-finish timing without the excluded frontend work.
    budget = raw_seconds * 3 / 300
    return {
        "request": request, "rawClipSeconds": raw_seconds,
        "analyzeSeconds": values[0], "applySeconds": values[1],
        "analyzeAndApplySeconds": total, "targetSeconds": budget,
        "targetDefinition": "3 seconds per 300 seconds of raw clip audio",
        "rawAudioSecondsPerProcessingSecond": raw_seconds / total,
        "helperProcessingWithinBudget": total <= budget,
        "importedProjectAndSourcesVerified": True,
        "processedPCMEqualityEstablished": False,
        "scope": "Automated helper Analyze + verified Apply, including their cleanup; "
                 "excludes human review, optional updates/navigation, frontend latency and startup. "
                 "This is not a stopwatch measurement of the complete UI workflow.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--analysis", required=True, type=Path)
    parser.add_argument("--apply", required=True, type=Path)
    parser.add_argument("--result-directory", required=True, type=Path)
    parser.add_argument("--raw-seconds", required=True, type=float)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    def read(path):
        return json.loads(path.read_text())
    try:
        directory = args.result_directory
        result = make_report(read(args.analysis), read(args.apply),
            read(directory / "Import-Verification.json"),
            read(directory / "Verification-Receipt.json"),
            read(directory / "Edit-Report.json"),
            (directory / "Silent Snip.fcpxml").read_bytes(), args.raw_seconds)
        text = json.dumps(result, indent=2, allow_nan=False) + "\n"
        if args.output:
            with args.output.open("x") as stream:
                stream.write(text)
        print(text, end="")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    main()
