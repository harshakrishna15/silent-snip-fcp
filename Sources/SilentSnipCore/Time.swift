import Foundation

public enum RationalTimeError: Error, Equatable, LocalizedError {
    case invalidFormat(String)
    case invalidDenominator
    case unrepresentableSeconds
    case arithmeticOverflow
    case invalidFrameDuration

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let value): return "Invalid rational time: \(value)."
        case .invalidDenominator: return "A time denominator must be positive."
        case .unrepresentableSeconds: return "The time is not finite or cannot be represented."
        case .arithmeticOverflow: return "The time calculation exceeds the supported precision or duration."
        case .invalidFrameDuration: return "The project frame duration must be positive."
        }
    }
}

/// Exact seconds. Frame and sample boundaries stay rational until display.
public struct RationalTime: Codable, Hashable, Comparable, Sendable {
    public let numerator: Int64
    public let denominator: Int64

    public init(_ numerator: Int64, _ denominator: Int64 = 1) {
        precondition(denominator > 0, "A time denominator must be positive")
        let divisor = Int64(Self.gcd(numerator.magnitude, UInt64(denominator)))
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    public init(seconds: Double, timescale: Int64 = 1_000_000_000) throws {
        guard timescale > 0 else { throw RationalTimeError.invalidDenominator }
        let ticks = (seconds * Double(timescale)).rounded()
        // Double(Int64.max) rounds up; use a strict upper bound before converting.
        guard ticks.isFinite, ticks >= Double(Int64.min), ticks < Double(Int64.max) else {
            throw RationalTimeError.unrepresentableSeconds
        }
        self.init(Int64(ticks), timescale)
    }

    public static let zero = RationalTime(0)
    public var seconds: Double { Double(numerator) / Double(denominator) }

    /// Reads the integer and rational forms used by FCPXML, with an optional `s` suffix.
    public static func parse(_ text: String) throws -> RationalTime {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("s") { value.removeLast() }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let numerator = Int64(parts[0]) else {
            throw RationalTimeError.invalidFormat(text)
        }
        if parts.count == 1 { return RationalTime(numerator) }
        guard let denominator = Int64(parts[1]) else { throw RationalTimeError.invalidFormat(text) }
        guard denominator > 0 else { throw RationalTimeError.invalidDenominator }
        return RationalTime(numerator, denominator)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        let left = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
        let right = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
        return left.high == right.high ? left.low < right.low : left.high < right.high
    }

    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        try! lhs.adding(rhs)
    }

    public static prefix func - (value: RationalTime) -> RationalTime {
        precondition(value.numerator != Int64.min, "Rational time negation overflow")
        return RationalTime(-value.numerator, value.denominator)
    }

    public static func - (lhs: RationalTime, rhs: RationalTime) -> RationalTime { try! lhs.subtracting(rhs) }

    public static func * (lhs: RationalTime, rhs: Int64) -> RationalTime {
        lhs * RationalTime(rhs)
    }

    public static func * (lhs: Int64, rhs: RationalTime) -> RationalTime { rhs * lhs }

    public static func * (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        try! lhs.multiplied(by: rhs)
    }

    /// Checked operations are for timing read from untrusted project documents.
    public func adding(_ other: RationalTime) throws -> RationalTime {
        try combining(other, subtract: false)
    }

    public func subtracting(_ other: RationalTime) throws -> RationalTime {
        try combining(other, subtract: true)
    }

    public func multiplied(by other: RationalTime) throws -> RationalTime {
        let leftDivisor = Int64(Self.gcd(numerator.magnitude, UInt64(other.denominator)))
        let rightDivisor = Int64(Self.gcd(other.numerator.magnitude, UInt64(denominator)))
        return RationalTime(
            try Self.safeMultiply(numerator / leftDivisor, other.numerator / rightDivisor),
            try Self.safeMultiply(denominator / rightDivisor, other.denominator / leftDivisor)
        )
    }

    private func combining(_ other: RationalTime, subtract: Bool) throws -> RationalTime {
        let divisor = Int64(Self.gcd(UInt64(denominator), UInt64(other.denominator)))
        let leftFactor = other.denominator / divisor
        let rightFactor = denominator / divisor
        let left = try Self.safeMultiply(numerator, leftFactor)
        let right = try Self.safeMultiply(other.numerator, rightFactor)
        let result = subtract ? left.subtractingReportingOverflow(right) : left.addingReportingOverflow(right)
        guard !result.overflow else { throw RationalTimeError.arithmeticOverflow }
        return RationalTime(result.partialValue, try Self.safeMultiply(denominator, leftFactor))
    }

    public static func / (lhs: RationalTime, rhs: Int64) -> RationalTime {
        precondition(rhs > 0, "Time division requires a positive divisor")
        return lhs * RationalTime(1, rhs)
    }

    public func floor(toFrame frame: RationalTime) -> RationalTime {
        try! roundedDown(toFrame: frame)
    }

    public func ceil(toFrame frame: RationalTime) -> RationalTime {
        try! roundedUp(toFrame: frame)
    }

    public func roundedDown(toFrame frame: RationalTime) throws -> RationalTime {
        try rounded(toFrame: frame, upward: false)
    }

    public func roundedUp(toFrame frame: RationalTime) throws -> RationalTime {
        try rounded(toFrame: frame, upward: true)
    }

    private func rounded(toFrame frame: RationalTime, upward: Bool) throws -> RationalTime {
        guard frame > .zero else { throw RationalTimeError.invalidFrameDuration }
        let frameCount = try multiplied(by: RationalTime(frame.denominator, frame.numerator))
        var count = frameCount.numerator / frameCount.denominator
        let remainder = frameCount.numerator % frameCount.denominator
        if remainder != 0 {
            let adjustment: Int64 = upward && remainder > 0 ? 1 : (!upward && remainder < 0 ? -1 : 0)
            let result = count.addingReportingOverflow(adjustment)
            guard !result.overflow else { throw RationalTimeError.arithmeticOverflow }
            count = result.partialValue
        }
        return try frame.multiplied(by: RationalTime(count))
    }

    private static func safeMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw RationalTimeError.arithmeticOverflow }
        return result.partialValue
    }

    private static func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }

    private enum CodingKeys: String, CodingKey { case numerator, denominator }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try values.decode(Int64.self, forKey: .numerator)
        let denominator = try values.decode(Int64.self, forKey: .denominator)
        guard denominator > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .denominator, in: values, debugDescription: "A time denominator must be positive")
        }
        self.init(numerator, denominator)
    }
}

/// A half-open interval: its start is included and its end is excluded.
public struct TimeRange: Codable, Hashable, Sendable {
    public let start: RationalTime
    public let end: RationalTime

    public init(start: RationalTime, end: RationalTime) {
        precondition(end >= start, "A time range cannot end before it starts")
        self.start = start
        self.end = end
    }

    public var duration: RationalTime { end - start }
    public func checkedDuration() throws -> RationalTime { try end.subtracting(start) }
    public var isEmpty: Bool { start == end }

    public func contains(_ time: RationalTime) -> Bool { start <= time && time < end }

    public func intersection(_ other: TimeRange) -> TimeRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        return upper > lower ? TimeRange(start: lower, end: upper) : nil
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let start = try values.decode(RationalTime.self, forKey: .start)
        let end = try values.decode(RationalTime.self, forKey: .end)
        guard end >= start else {
            throw DecodingError.dataCorruptedError(forKey: .end, in: values, debugDescription: "A time range cannot end before it starts")
        }
        _ = try end.subtracting(start)
        self.init(start: start, end: end)
    }
}
