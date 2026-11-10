import AVFoundation
import SilentSnipCore

public enum ReviewAuditionMode: String, Codable, Sendable {
    case original, proposed
}

enum SourceCutAudition {
    enum Segment: Equatable {
        case source(TimeRange)
        case gap(RationalTime)
    }

    static func segments(clip: TimeRange, source: TimeRange, cut: TimeRange,
                         mode: ReviewAuditionMode, gap: RationalTime? = nil) throws -> [Segment] {
        guard clip.intersection(cut) == cut, source.start >= .zero,
              try source.checkedDuration() == clip.checkedDuration() else { throw ReviewError.invalidRange }
        let context = RationalTime(7, 20)
        let lower = max(clip.start, try cut.start.subtracting(context))
        let upper = min(clip.end, try cut.end.adding(context))
        func sourceTime(_ time: RationalTime) throws -> RationalTime {
            try source.start.adding(time.subtracting(clip.start))
        }
        let start = try sourceTime(lower), end = try sourceTime(upper)
        if mode == .original { return [.source(TimeRange(start: start, end: end))] }
        guard cut != clip else { throw ReviewError.invalidRange }
        var result: [Segment] = []
        if lower < cut.start { result.append(.source(TimeRange(start: start, end: try sourceTime(cut.start)))) }
        if let gap, gap > .zero { result.append(.gap(gap)) }
        if cut.end < upper { result.append(.source(TimeRange(start: try sourceTime(cut.end), end: end))) }
        return result
    }

    @MainActor static func composition(url: URL, segments: [Segment]) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else { throw SourceAudioError.multipleTracks }
        let sourceBounds = try await track.load(.timeRange)
        guard sourceBounds.isValid, sourceBounds.start.isNumeric else { throw SourceAudioError.invalidRange }
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SourceAudioError.invalidAudio
        }
        func time(_ rational: RationalTime) throws -> CMTime {
            guard let scale = Int32(exactly: rational.denominator) else { throw SourceAudioError.invalidRange }
            return CMTime(value: rational.numerator, timescale: scale)
        }
        var position = RationalTime.zero
        for segment in segments {
            let duration: RationalTime
            switch segment {
            case .source(let range):
                duration = try range.checkedDuration()
                let start = CMTimeAdd(sourceBounds.start, try time(range.start))
                let span = CMTimeRange(start: start, duration: try time(duration))
                guard start.isNumeric, !start.hasBeenRounded, CMTimeCompare(start, sourceBounds.start) >= 0,
                      CMTimeCompare(span.end, sourceBounds.end) <= 0 else {
                    throw SourceAudioError.invalidRange
                }
                try output.insertTimeRange(span, of: track, at: time(position))
            case .gap(let gap):
                duration = gap
                output.insertEmptyTimeRange(CMTimeRange(start: try time(position), duration: try time(duration)))
            }
            position = try position.adding(duration)
        }
        return composition
    }
}
