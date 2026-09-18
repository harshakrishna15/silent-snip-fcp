import Foundation
import CutdownCore

/// A button press requests analysis, never permission to mutate a project.
public struct AnalyzeRequest: Equatable, Sendable {
    public let id: UUID
    public let settings: AnalysisSettings
    public let outputMode: CutdownOutputMode

    public init(id: UUID, settings: AnalysisSettings, outputMode: CutdownOutputMode) {
        self.id = id; self.settings = settings; self.outputMode = outputMode
    }

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "cutdown", parts.host == "analyze",
              parts.path.isEmpty, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw RequestError.invalidURL
        }
        let allowed = Set(["request", "threshold", "minimum", "before", "after", "output"])
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard allowed.contains(item.name), values[item.name] == nil, let value = item.value else {
                throw RequestError.invalidURL
            }
            values[item.name] = value
        }
        guard let identifier = values["request"], let id = UUID(uuidString: identifier),
              let threshold = values["threshold"].flatMap(Double.init),
              let minimum = values["minimum"].flatMap(Double.init),
              let before = values["before"].flatMap(Double.init),
              let after = values["after"].flatMap(Double.init) else {
            throw RequestError.invalidURL
        }
        guard let mode = CutdownOutputMode(rawValue: values["output"] ?? "remove") else { throw RequestError.invalidURL }
        self.outputMode = mode
        self.id = id
        self.settings = try AnalysisSettings(
            thresholdDBFS: threshold, minimumSilenceDuration: minimum,
            beforeSpeechPadding: before, afterSpeechPadding: after, windowDuration: 0.01
        )
    }

    public enum RequestError: LocalizedError {
        case invalidURL
        public var errorDescription: String? { "The Cutdown analysis request is invalid. Analyze again from the effect’s Inspector controls." }
    }
}

public enum CutdownOutputMode: String, Sendable {
    case remove, gaps

    public func gapDuration(frame: RationalTime) throws -> RationalTime? {
        guard self == .gaps else { return nil }
        let second = RationalTime(1)
        let lower = try second.roundedDown(toFrame: frame)
        let upper = try second.roundedUp(toFrame: frame)
        return try second.subtracting(lower) < upper.subtracting(second) && lower > .zero ? lower : upper
    }
}

/// Explicit recovery chosen in Controls; contains a local result, never media.
public struct ReviewVerificationRequest {
    public let view: UUID
    public let result: URL
    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "cutdown", parts.host == "verify", parts.path.isEmpty,
              parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.queryItems?.count == 2,
              let viewText = parts.queryItems?.first(where: { $0.name == "view" })?.value,
              let view = UUID(uuidString: viewText),
              let path = parts.queryItems?.first(where: { $0.name == "result" })?.value,
              let result = URL(string: path), result.isFileURL,
              result.host == nil || result.host == "" || result.host == "localhost",
              result.lastPathComponent == "Cutdown.fcpxml" else { throw AnalyzeRequest.RequestError.invalidURL }
        self.view = view; self.result = result
    }
}
