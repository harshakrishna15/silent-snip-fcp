#!/usr/bin/env python3
"""Compare native cleaned audio with exact retained samples and optional zero gaps.

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
import uuid


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


def replacement_gap_frames(report, cuts, origin, duration, result_duration, rate, inserted):
    """Bind the app's uniform replacement gaps to its retained-range evidence.

    insertedGapDuration is a total, not a per-cut duration. The core writer can
    also produce nonuniform gaps, so the total alone cannot establish where
    silence belongs. Require the target's complete retained-range complement
    and its exact original-to-result mapping before accepting the uniform plan.
    Adjacent cuts have no retained samples between them; their contiguous zero
    spans are equivalent only when the mapped cumulative duration also agrees.
    """
    if inserted < 0:
        raise ComparisonError("Inserted gap duration cannot be negative")
    if inserted == 0:
        return 0
    if not cuts:
        raise ComparisonError("Replacement gaps require selected cut ranges")
    gap_duration = inserted / len(cuts)
    frames = sample_frame(gap_duration, rate, "Each replacement gap duration")
    segments = report.get("retainedSegments")
    if not isinstance(segments, list) or not segments:
        raise ComparisonError("Replacement gaps require complete retainedSegments mapping evidence")
    times = [(Fraction(start, rate), Fraction(end, rate)) for start, end in cuts]
    original_ranges = []
    previous = Fraction(0)
    for i, segment in enumerate(segments):
        if not isinstance(segment, dict):
            raise ComparisonError(f"retainedSegments[{i}] must contain original/result ranges")
        original, result = segment.get("originalProjectRange"), segment.get("resultProjectRange")
        if not isinstance(original, dict) or not isinstance(result, dict):
            raise ComparisonError(f"retainedSegments[{i}] must contain original/result ranges")
        start = rational(original.get("start"), f"retainedSegments[{i}].original.start") - origin
        end = rational(original.get("end"), f"retainedSegments[{i}].original.end") - origin
        result_start = rational(result.get("start"), f"retainedSegments[{i}].result.start")
        result_end = rational(result.get("end"), f"retainedSegments[{i}].result.end")
        if start < previous or start < 0 or end <= start or end > duration:
            raise ComparisonError("Gap retained ranges must be ordered, nonoverlapping, and inside the original project")
        prior = [(a, b) for a, b in times if b <= start]
        expected_start = start - sum((b - a for a, b in prior), Fraction(0)) + len(prior) * gap_duration
        if (result_start != expected_start or result_end - result_start != end - start or
                result_start < 0 or result_end > result_duration):
            raise ComparisonError("Replacement gap durations do not match the retained original-to-result mapping")
        original_ranges.append((start, end))
        previous = end
    cursor = min(original_ranges[0][0], times[0][0])
    target_end = max(original_ranges[-1][1], times[-1][1])
    expected_keeps = []
    for start, end in times:
        if cursor < start:
            expected_keeps.append((cursor, start))
        cursor = end
    if cursor < target_end:
        expected_keeps.append((cursor, target_end))
    if original_ranges != expected_keeps:
        raise ComparisonError("Replacement gaps require the complete retained target-range complement")
    return frames


def encoded_wave_evidence(path):
    """Hash exact encoded bytes, PCM payload, and format without PCM conversion."""
    encoded, pcm, fmt = hashlib.sha256(), hashlib.sha256(), hashlib.sha256()
    counts = {b"data": 0, b"fmt ": 0}
    size = Path(path).stat().st_size
    with Path(path).open("rb") as stream:
        def read(count):
            data = stream.read(count)
            if len(data) != count:
                raise ComparisonError("Native WAV provenance contains an incomplete RIFF chunk")
            encoded.update(data)
            return data
        header = read(12)
        if header[:4] != b"RIFF" or header[8:] != b"WAVE" or struct.unpack_from("<I", header, 4)[0] + 8 != size:
            raise ComparisonError("Native WAV provenance requires a complete RIFF WAVE container")
        while stream.tell() < size:
            tag, count = struct.unpack("<4sI", read(8))
            if count + count % 2 > size - stream.tell():
                raise ComparisonError("Native WAV provenance chunk exceeds the file")
            if tag in counts:
                counts[tag] += 1
            remaining = count
            while remaining:
                data = read(min(1024 * 1024, remaining))
                if tag == b"data":
                    pcm.update(data)
                elif tag == b"fmt ":
                    fmt.update(data)
                remaining -= len(data)
            if count % 2:
                read(1)
    if counts != {b"data": 1, b"fmt ": 1}:
        raise ComparisonError("Native WAV provenance requires one audio payload and one format chunk")
    return {"sha256": encoded.hexdigest(), "pcmDataSHA256": pcm.hexdigest(), "formatDataSHA256": fmt.hexdigest()}


def bound_project_tail(report, original, duration, origin, metadata):
    """Only a byte-bound full native mix can describe a fractional project end.

    New cuts are still exact PCM frames. Final Cut's observed WAV end is
    floor(T*rate); preserve that existing tail phase, never round cut bounds.
    """
    audio = report.get("losslessAudio")
    if not isinstance(audio, dict) or audio.get("scope") != "projectMix":
        raise ComparisonError("A fractional project tail requires bound projectMix audio provenance")
    count = audio.get("frameCount")
    logical_frames = duration * metadata["sampleRate"]
    if (type(count) is not int or type(audio.get("sampleRate")) is not int or type(audio.get("channelCount")) is not int or
            count <= 0 or count != logical_frames.numerator // logical_frames.denominator or
            audio.get("sampleRate") != metadata["sampleRate"] or audio.get("channelCount") != metadata["channels"]):
        raise ComparisonError("Native project tail metadata must match exactly floor(T*sampleRate)")
    bounds = audio.get("timelineRange")
    if (not isinstance(bounds, dict) or rational(bounds.get("start"), "losslessAudio.timelineRange.start") != origin or
            rational(bounds.get("end"), "losslessAudio.timelineRange.end") != origin + duration):
        raise ComparisonError("Native audio provenance does not cover the complete original project")
    expected = audio.get("sha256")
    if not isinstance(expected, str) or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise ComparisonError("Native audio provenance must contain its encoded-file SHA256")
    proof_keys = ("nativeSourceSHA256", "pcmDataSHA256", "formatDataSHA256", "mediaIdentity")
    has_proof = any(audio.get(key) is not None for key in proof_keys)
    if has_proof:
        for key in proof_keys[:3]:
            value = audio.get(key)
            if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
                raise ComparisonError("Native identity provenance requires complete encoded/PCM/format hashes")
        try:
            uuid.UUID(audio["mediaIdentity"])
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise ComparisonError("Native identity provenance requires a valid media UUID") from error
    path = Path(original)
    before = path.stat()
    evidence = encoded_wave_evidence(path)
    after = path.stat()
    stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    accepted_hashes = {expected, audio["nativeSourceSHA256"]} if has_proof else {expected}
    if stamp(before) != stamp(after) or evidence["sha256"] not in accepted_hashes:
        raise ComparisonError("Original native WAV bytes do not match the project-tail provenance")
    if has_proof and any(evidence[key] != audio[key] for key in ("pcmDataSHA256", "formatDataSHA256")):
        raise ComparisonError("Original native WAV PCM/format bytes do not match the retained identity provenance")
    return count, stamp(after), evidence["sha256"]


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
    inserted = rational(report.get("insertedGapDuration"), "insertedGapDuration")
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
    native_tail_stamp = None
    native_tail_encoded_hash = None
    if (duration * rate).denominator == 1:
        original_frames = sample_frame(duration, rate, "original duration")
    else:
        original_frames, native_tail_stamp, native_tail_encoded_hash = bound_project_tail(report, original, duration, origin, metadata)
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
    if duration - removed + inserted != result_duration:
        raise ComparisonError("Result duration does not equal original duration minus selected ranges plus inserted gaps")
    gap_frames = replacement_gap_frames(report, cuts, origin, duration, result_duration, rate, inserted)
    exact_removed_frames = sample_frame(removed, rate, "removed duration")
    if original_frames - exact_removed_frames < 0:
        raise ComparisonError("Selected ranges exceed the verified native PCM frame count")
    inserted_frames = sample_frame(inserted, rate, "inserted gap duration")
    result_frames = original_frames - exact_removed_frames + inserted_frames
    if native_tail_stamp is None:
        if sample_frame(result_duration, rate, "result duration") != result_frames:
            raise ComparisonError("The result PCM duration does not match the selected ranges")
    elif result_duration * rate - result_frames != duration * rate - original_frames:
        raise ComparisonError("The edited project changed its native fractional tail phase")
    boundaries, removed_frames, prior_gap_frames = [], 0, 0
    for start, end in cuts:
        position = start - removed_frames + prior_gap_frames
        boundaries.append({"resultFrame": position, "resultSeconds": position / rate,
                           "originalCutStartFrame": start, "originalCutEndFrame": end})
        if gap_frames:
            boundaries[-1].update(gapStartFrame=position, gapEndFrame=position + gap_frames,
                                  gapFrames=gap_frames, gapEndSeconds=(position + gap_frames) / rate)
        removed_frames += end - start
        prior_gap_frames += gap_frames
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

        for cut_index, (keep_end, skip_end) in enumerate(cuts + [(original_frames, original_frames)]):
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
            remaining_gap = gap_frames if cut_index < len(cuts) else 0
            while remaining_gap:
                count = min(BLOCK_FRAMES, remaining_gap)
                expected = bytes(count * channels * 4)
                actual = output.read(count)
                expected_hash.update(expected)
                if mismatch is None:
                    mismatch = first_difference(expected, actual, channels, output_position, source_position)
                    if mismatch:
                        mismatch.pop("originalFrame")
                        mismatch.update(region="insertedGap", gapIndex=cut_index,
                                        framesFromGapStart=mismatch["resultFrame"] - boundaries[cut_index]["gapStartFrame"])
                        if mismatch["kind"] == "sampleMismatch":
                            mismatch["kind"] = "nonzeroInsertedGapSample"
                output_position += count
                remaining_gap -= count
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
                nearest = min(boundaries, key=lambda b: min(abs(b["resultFrame"] - mismatch["resultFrame"]),
                              abs(b.get("gapEndFrame", b["resultFrame"]) - mismatch["resultFrame"])))
                mismatch["nearestCutBoundary"] = nearest
                boundary_frame = min((nearest["resultFrame"], nearest.get("gapEndFrame", nearest["resultFrame"])),
                                     key=lambda frame: abs(frame - mismatch["resultFrame"]))
                mismatch["framesFromBoundary"] = mismatch["resultFrame"] - boundary_frame
        if repeat_mismatch:
            repeat_mismatch["originalSeconds"] = repeat_mismatch["originalFrame"] / rate
            if cuts:
                nearest = min((frame for cut in cuts for frame in cut),
                              key=lambda frame: abs(frame - repeat_mismatch["originalFrame"]))
                repeat_mismatch["nearestOriginalCutBoundaryFrame"] = nearest
                repeat_mismatch["framesFromOriginalBoundary"] = repeat_mismatch["originalFrame"] - nearest
        identical = mismatch is None and expected_hash.digest() == output.sha256.digest()
        deterministic = repeated is not None and repeat_mismatch is None and source.sha256.digest() == repeated.sha256.digest()
        if native_tail_stamp is not None:
            current = Path(original).stat()
            if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns, current.st_ctime_ns) != native_tail_stamp:
                raise ComparisonError("Original native WAV changed during the tail-bound comparison")
        return {"valid": True, "passes": identical and (not repeated or deterministic),
                "pcmIdentical": identical, "originalDeterminismVerified": deterministic,
                "format": dict(metadata, comparisonPCM="Float32 little-endian, interleaved; no requested resampling"),
                "originalFrames": source.frames, "expectedCleanedFrames": result_frames,
                "actualCleanedFrames": output.frames, "originalPCM_SHA256": source.sha256.hexdigest(),
                "expectedCleanedPCM_SHA256": expected_hash.hexdigest(), "cleanedPCM_SHA256": output.sha256.hexdigest(),
                "firstDifference": mismatch, "cutBoundaries": boundaries,
                "outputMode": "replaceWithSilenceGaps" if gap_frames else "removeSilence",
                "insertedGapFrames": inserted_frames,
                "replacementGapFrames": gap_frames,
                "gapPlanEvidence": None if not gap_frames else "Uniform per-cut duration from total/count; exact retained target-range complement and result mappings verified.",
                "nativeFractionalTail": None if native_tail_stamp is None else {
                    "originalFrameCount": original_frames, "resultFrameCount": result_frames,
                    "fractionalLogicalSamples": str(duration * rate - original_frames),
                    "originalFileSHA256": native_tail_encoded_hash,
                    "durableFileSHA256": report["losslessAudio"]["sha256"],
                    "pcmDataSHA256": report["losslessAudio"].get("pcmDataSHA256"),
                    "rule": "Bound native projectMix WAV ends at floor(T*rate); all cut boundaries remain exact samples."},
                "originalRepeat": None if not repeated else {"pcmIdentical": deterministic,
                    "frames": repeated.frames, "pcmSHA256": repeated.sha256.hexdigest(), "firstDifference": repeat_mismatch},
                "scope": "Supplied native exports only; every retained sample and each declared replacement gap (exact positive-zero PCM) are compared without tolerance or timing shift."}
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
