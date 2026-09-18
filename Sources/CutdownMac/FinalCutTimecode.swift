import CutdownCore
import Foundation

public enum FinalCutTimecode {
    public static func time(_ text: String, frameDuration: RationalTime) throws -> RationalTime {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let supported: [(RationalTime, Int64)] = [
            (RationalTime(1, 24), 24), (RationalTime(1001, 24000), 24),
            (RationalTime(1, 25), 25), (RationalTime(1, 30), 30),
            (RationalTime(1001, 30000), 30), (RationalTime(1, 50), 50),
            (RationalTime(1, 60), 60), (RationalTime(1001, 60000), 60)
        ]
        guard let nominal = supported.first(where: { $0.0 == frameDuration })?.1,
              text.count == 11, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ";") }) else {
            throw FinalCutCaptureError.unsupportedTimecode(text)
        }
        let chars = Array(text)
        guard chars[2] == ":", chars[5] == ":", chars[8] == ":" || chars[8] == ";" else {
            throw FinalCutCaptureError.unsupportedTimecode(text)
        }
        let parts = text.replacingOccurrences(of: ";", with: ":").split(separator: ":")
        guard parts.count == 4, parts.allSatisfy({ $0.count == 2 }),
              let hour = Int64(parts[0]), let minute = Int64(parts[1]),
              let second = Int64(parts[2]), let frame = Int64(parts[3]),
              minute < 60, second < 60, frame < nominal else {
            throw FinalCutCaptureError.unsupportedTimecode(text)
        }
        var frames = ((hour * 60 + minute) * 60 + second) * nominal + frame
        if chars[8] == ";" {
            guard frameDuration == RationalTime(1001, 30000) || frameDuration == RationalTime(1001, 60000) else {
                throw FinalCutCaptureError.unsupportedTimecode(text)
            }
            let dropped = nominal / 15
            guard minute % 10 == 0 || second != 0 || frame >= dropped else {
                throw FinalCutCaptureError.unsupportedTimecode(text)
            }
            let totalMinutes = hour * 60 + minute
            frames -= dropped * (totalMinutes - totalMinutes / 10)
        }
        return try frameDuration.multiplied(by: RationalTime(frames))
    }

    public static func format(_ time: RationalTime, frameDuration: RationalTime, dropFrame: Bool = false) throws -> String {
        guard frameDuration > .zero, time >= .zero else { throw FinalCutCaptureError.unsupportedTimecode("negative or invalid frame time") }
        let nominal: Int64
        switch frameDuration {
        case RationalTime(1, 24), RationalTime(1001, 24000): nominal = 24
        case RationalTime(1, 25): nominal = 25
        case RationalTime(1, 30), RationalTime(1001, 30000): nominal = 30
        case RationalTime(1, 50): nominal = 50
        case RationalTime(1, 60), RationalTime(1001, 60000): nominal = 60
        default: throw FinalCutCaptureError.unsupportedTimecode("unsupported frame rate")
        }
        let count = try time.multiplied(by: RationalTime(frameDuration.denominator, frameDuration.numerator))
        guard count.denominator == 1, count.numerator < nominal * 360_000 else {
            throw FinalCutCaptureError.unsupportedTimecode("time is not a project frame or exceeds 99 hours")
        }
        var frames = count.numerator
        if dropFrame {
            guard frameDuration == RationalTime(1001, 30000) || frameDuration == RationalTime(1001, 60000) else {
                throw FinalCutCaptureError.unsupportedTimecode("drop frame requires 29.97 or 59.94 fps")
            }
            let dropped = nominal / 15
            let framesPerTenMinutes = nominal * 600 - dropped * 9
            let tens = frames / framesPerTenMinutes
            let remainder = frames % framesPerTenMinutes
            frames += dropped * 9 * tens
            if remainder > dropped { frames += dropped * ((remainder - dropped) / (nominal * 60 - dropped)) }
        }
        let hours = frames / (nominal * 3600)
        guard hours < 100 else { throw FinalCutCaptureError.unsupportedTimecode("time exceeds 99 hours") }
        let minutes = (frames / (nominal * 60)) % 60
        let seconds = (frames / nominal) % 60
        return String(format: "%02lld:%02lld:%02lld%@%02lld", hours, minutes, seconds, dropFrame ? ";" : ":", frames % nominal)
    }
}

