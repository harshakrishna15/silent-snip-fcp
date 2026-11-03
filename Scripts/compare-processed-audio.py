#!/usr/bin/env python3
"""Compare native cleaned audio with the original processed audio minus exact cuts.

Developer evidence only. Accepts uncompressed WAV with integer PCM up to 24 bits
or Float32 PCM, whose samples can be represented exactly by the Float32 decoder.
No resampling, channel conversion, normalization, or timing shift is requested.
No PCM files are written. Exit 0 means equality, 1 a difference, 2 invalid input.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading


BLOCK_FRAMES = 16_384
SUPPORTED_PCM = {"pcm_u8": ("u8", 8), "pcm_s16le": ("s16", 16),
                 "pcm_s24le": ("s32", 24), "pcm_f32le": ("flt", 32)}


class ComparisonError(ValueError):
    pass


def rational(value, label):
    if not isinstance(value, dict):
        raise ComparisonError(f"{label} must be an exact rational time")
    n, d = value.get("numerator"), value.get("denominator")
    if type(n) is not int or type(d) is not int or d <= 0:
        raise ComparisonError(f"{label} has invalid numerator/denominator")
    return Fraction(n, d)


def sample_frame(time, rate, label):
    frame = time * rate
    if frame.denominator != 1:
        raise ComparisonError(f"{label} is not on an exact audio sample boundary")
    return frame.numerator


def probe(path):
    command = ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ComparisonError(f"ffprobe failed for {path}: {result.stderr[:2000]}")
    try:
        metadata = json.loads(result.stdout)
        if metadata.get("format", {}).get("format_name") != "wav":
            raise ComparisonError("Only uncompressed PCM WAV exports are supported")
        streams = [s for s in metadata["streams"] if s.get("codec_type") == "audio"]
        if len(streams) != 1:
            raise ComparisonError("Each input must have exactly one audio stream")
        s = streams[0]
        codec = s.get("codec_name")
        declared = SUPPORTED_PCM.get(codec)
        if (declared is None or s.get("sample_fmt") != declared[0] or
                int(s.get("bits_per_sample", 0)) != declared[1]):
            raise ComparisonError("Unsupported PCM precision/codec; use integer PCM WAV up to 24 bits or Float32 WAV")
        rate, channels = int(s["sample_rate"]), int(s["channels"])
        if rate <= 0 or channels <= 0:
            raise ComparisonError("Invalid sample rate/channel count")
        return {"sampleRate": rate, "channels": channels,
                "channelLayout": s.get("channel_layout") or f"unspecified:{channels}",
                "codec": codec, "bitsPerSample": declared[1]}
    except (KeyError, TypeError, ValueError) as error:
        raise ComparisonError(f"Invalid ffprobe metadata: {error}") from error


class Decoder:
    def __init__(self, path, channels):
        self.frame_bytes = channels * 4
        self.frames = 0
        self.sha256 = hashlib.sha256()
        self.process = subprocess.Popen(
            ["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", str(path),
             "-map", "0:a:0", "-vn", "-sn", "-dn", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.error = bytearray()
        # Drain diagnostics concurrently: a damaged source must not fill the
        # stderr pipe and stall stdout. Retain only a bounded diagnostic prefix.
        def drain_error():
            while block := self.process.stderr.read(4096):
                self.error.extend(block[:max(0, 2000 - len(self.error))])
        self.error_thread = threading.Thread(target=drain_error, daemon=True)
        self.error_thread.start()
        self.finished = False

    def read(self, frames):
        data = self.process.stdout.read(frames * self.frame_bytes)
        if len(data) % self.frame_bytes:
            raise ComparisonError("Decoder returned an incomplete PCM frame")
        self.frames += len(data) // self.frame_bytes
        self.sha256.update(data)
        if not data and not self.finished:
            self.finished = True
            status = self.process.wait()
            self.error_thread.join()
            if status != 0:
                raise ComparisonError(f"ffmpeg failed: {self.error.decode(errors='replace')}")
        return data

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.error_thread.join()
        self.process.stdout.close()
        self.process.stderr.close()


def first_difference(expected, actual, channels, result_start, original_start):
    # Equal blocks are the normal case. Keep the per-sample Python scan only
    # for the first differing block so long native exports remain practical.
    if expected == actual:
        return None
    common = min(len(expected), len(actual))
    offset = next((i for i in range(0, common, 4) if expected[i:i + 4] != actual[i:i + 4]), common)
    frame, channel = divmod(offset // 4, channels)
    result = {"resultFrame": result_start + frame, "originalFrame": original_start + frame,
              "channel": channel,
              "kind": "sampleMismatch" if offset < common else "missingCleanedFrame"}
    if offset < common:
        expected_value, actual_value = struct.unpack_from("<f", expected, offset)[0], struct.unpack_from("<f", actual, offset)[0]
        result.update(expectedFloat32Bits=expected[offset:offset + 4].hex(),
                      actualFloat32Bits=actual[offset:offset + 4].hex(),
                      expectedValue=expected_value if math.isfinite(expected_value) else repr(expected_value),
                      actualValue=actual_value if math.isfinite(actual_value) else repr(actual_value))
    return result


def compare(original, cleaned, edit_report, repeated_original=None):
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            raise ComparisonError(f"Required tool unavailable: {tool}")
    report = json.loads(Path(edit_report).read_text())
    if not isinstance(report, dict):
        raise ComparisonError("Edit report must be a JSON object")
    if rational(report.get("insertedGapDuration"), "insertedGapDuration") != 0:
        raise ComparisonError("Only Remove Silence results are supported; inserted gaps are rejected")
    duration = rational(report.get("originalProjectDuration"), "originalProjectDuration")
    result_duration = rational(report.get("resultProjectDuration"), "resultProjectDuration")
    if duration <= 0 or result_duration < 0:
        raise ComparisonError("Invalid project durations")
    # Native Edit-Report ranges are already relative to project zero. An
    # explicit enclosing range can describe a different origin; never infer an
    # origin from the first target segment (that would discard the lead-in).
    origin = Fraction(0)
    if "originalProjectRange" in report:
        bounds = report["originalProjectRange"]
        if not isinstance(bounds, dict):
            raise ComparisonError("originalProjectRange must contain start/end rational times")
        origin = rational(bounds.get("start"), "originalProjectRange.start")
        if rational(bounds.get("end"), "originalProjectRange.end") - origin != duration:
            raise ComparisonError("The enclosing original project range has the wrong duration")
    metadata = probe(original)
    if probe(cleaned) != metadata:
        raise ComparisonError("Original and cleaned sample rate/channel count/layout or PCM format differ")
    if repeated_original and probe(repeated_original) != metadata:
        raise ComparisonError("Repeated original sample rate/channel count/layout or PCM format differ")
    rate, channels = metadata["sampleRate"], metadata["channels"]
    original_frames = sample_frame(duration, rate, "original duration")
    result_frames = sample_frame(result_duration, rate, "result duration")
    cuts, previous, removed = [], Fraction(0), Fraction(0)
    ranges = report.get("selectedRanges")
    if not isinstance(ranges, list):
        raise ComparisonError("selectedRanges must be a list")
    for i, item in enumerate(ranges):
        if not isinstance(item, dict):
            raise ComparisonError(f"cut {i} must contain start/end rational times")
        start = rational(item.get("start"), f"cut {i}.start") - origin
        end = rational(item.get("end"), f"cut {i}.end") - origin
        if start < previous or start < 0 or end <= start or end > duration:
            raise ComparisonError("Cut ranges must be ordered, nonoverlapping, and inside the original project")
        cuts.append((sample_frame(start, rate, f"cut {i}.start"), sample_frame(end, rate, f"cut {i}.end")))
        previous, removed = end, removed + end - start
    if duration - removed != result_duration:
        raise ComparisonError("Result duration does not equal original duration minus selected ranges")
    boundaries, removed_frames = [], 0
    for start, end in cuts:
        position = start - removed_frames
        boundaries.append({"resultFrame": position, "resultSeconds": position / rate,
                           "originalCutStartFrame": start, "originalCutEndFrame": end})
        removed_frames += end - start
    source, output, repeated = None, None, None
    try:
        source = Decoder(original, channels)
        output = Decoder(cleaned, channels)
        repeated = Decoder(repeated_original, channels) if repeated_original else None
        expected_hash = hashlib.sha256()
        mismatch, repeat_mismatch = None, None
        source_position, output_position = 0, 0

        def read_original(count):
            nonlocal repeat_mismatch
            position = source.frames
            data = source.read(count)
            if repeated:
                again = repeated.read(count)
                if repeat_mismatch is None:
                    repeat_mismatch = first_difference(data, again, channels, position, position)
            return data

        for keep_end, skip_end in cuts + [(original_frames, original_frames)]:
            while source_position < keep_end:
                count = min(BLOCK_FRAMES, keep_end - source_position)
                expected = read_original(count)
                if len(expected) != count * channels * 4:
                    raise ComparisonError("Original render is shorter than the original project duration")
                actual = output.read(count)
                expected_hash.update(expected)
                if mismatch is None:
                    mismatch = first_difference(expected, actual, channels, output_position, source_position)
                source_position += count
                output_position += count
            while source_position < skip_end:
                count = min(BLOCK_FRAMES, skip_end - source_position)
                if len(read_original(count)) != count * channels * 4:
                    raise ComparisonError("Original render ends inside a selected cut")
                source_position += count
        if read_original(1):
            raise ComparisonError("Original render is longer than the original project duration")
        if repeated:
            if repeated.read(1):
                raise ComparisonError("Repeated original render is longer than the original project")
            if repeated.frames != original_frames:
                raise ComparisonError("Repeated original render has the wrong frame count")
        while extra := output.read(BLOCK_FRAMES):
            if mismatch is None:
                mismatch = {"resultFrame": result_frames, "kind": "extraCleanedFrame"}
        if output.frames != result_frames and mismatch is None:
            mismatch = {"resultFrame": min(output.frames, result_frames), "kind": "frameCountMismatch"}
        if mismatch:
            mismatch["resultSeconds"] = mismatch["resultFrame"] / rate
            if "originalFrame" in mismatch:
                mismatch["originalSeconds"] = mismatch["originalFrame"] / rate
            if boundaries:
                nearest = min(boundaries, key=lambda b: abs(b["resultFrame"] - mismatch["resultFrame"]))
                mismatch["nearestCutBoundary"] = nearest
                mismatch["framesFromBoundary"] = mismatch["resultFrame"] - nearest["resultFrame"]
        if repeat_mismatch:
            repeat_mismatch["originalSeconds"] = repeat_mismatch["originalFrame"] / rate
            if cuts:
                nearest = min((frame for cut in cuts for frame in cut),
                              key=lambda frame: abs(frame - repeat_mismatch["originalFrame"]))
                repeat_mismatch["nearestOriginalCutBoundaryFrame"] = nearest
                repeat_mismatch["framesFromOriginalBoundary"] = repeat_mismatch["originalFrame"] - nearest
        identical = mismatch is None and expected_hash.digest() == output.sha256.digest()
        deterministic = repeated is not None and repeat_mismatch is None and source.sha256.digest() == repeated.sha256.digest()
        return {"valid": True, "passes": identical and (not repeated or deterministic),
                "pcmIdentical": identical, "originalDeterminismVerified": deterministic,
                "format": dict(metadata, comparisonPCM="Float32 little-endian, interleaved; no requested resampling"),
                "originalFrames": source.frames, "expectedCleanedFrames": result_frames,
                "actualCleanedFrames": output.frames, "originalPCM_SHA256": source.sha256.hexdigest(),
                "expectedCleanedPCM_SHA256": expected_hash.hexdigest(), "cleanedPCM_SHA256": output.sha256.hexdigest(),
                "firstDifference": mismatch, "cutBoundaries": boundaries,
                "originalRepeat": None if not repeated else {"pcmIdentical": deterministic,
                    "frames": repeated.frames, "pcmSHA256": repeated.sha256.hexdigest(), "firstDifference": repeat_mismatch},
                "scope": "Supplied native exports only; output is compared after removing the exact project-zero cut ranges."}
    finally:
        for decoder in (source, output, repeated):
            if decoder:
                decoder.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original", type=Path, required=True)
    parser.add_argument("--cleaned", type=Path, required=True)
    parser.add_argument("--edit-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeated-original", type=Path)
    args = parser.parse_args()
    inputs = [args.original, args.cleaned, args.edit_report] + ([args.repeated_original] if args.repeated_original else [])
    if args.output.resolve() in {p.resolve() for p in inputs}:
        parser.error("The output report must not overwrite an input")
    try:
        result = compare(args.original, args.cleaned, args.edit_report, args.repeated_original)
        status = 0 if result["passes"] else 1
    except (ComparisonError, OSError, json.JSONDecodeError, TypeError, AttributeError) as error:
        result, status = {"valid": False, "passes": False, "pcmIdentical": False, "error": str(error)}, 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=args.output.parent, delete=False) as temporary:
        json.dump(result, temporary, indent=2, allow_nan=False)
        temporary.write("\n")
        temporary_name = temporary.name
    Path(temporary_name).replace(args.output)
    print(json.dumps({"passes": result["passes"], "report": str(args.output)}))
    return status


if __name__ == "__main__":
    raise SystemExit(main())
