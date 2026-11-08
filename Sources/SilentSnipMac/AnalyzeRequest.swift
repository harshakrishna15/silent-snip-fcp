import Foundation
import SilentSnipCore

/// A button press requests analysis, never permission to mutate a project.
public struct AnalyzeRequest: Equatable, Sendable {
    public let id: UUID
    public let settings: AnalysisSettings
    public let outputMode: SilentSnipOutputMode
    public let workflowOrigin: WorkflowReviewOrigin?

    public init(id: UUID, settings: AnalysisSettings, outputMode: SilentSnipOutputMode,
                workflowOrigin: WorkflowReviewOrigin? = nil) {
        self.id = id; self.settings = settings; self.outputMode = outputMode
        self.workflowOrigin = workflowOrigin
    }

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "silentsnip", ["analyze", "workflow-analyze"].contains(parts.host ?? ""),
              parts.path.isEmpty, parts.fragment == nil,
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw RequestError.invalidURL
        }
        let workflow = parts.host == "workflow-analyze"
        var allowed = Set(["request", "threshold", "minimum", "before", "after", "output"])
        if workflow { allowed.formUnion(["view", "gesture", "library", "project", "projectName"]) }
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
        guard let mode = SilentSnipOutputMode(rawValue: values["output"] ?? "remove") else { throw RequestError.invalidURL }
        self.outputMode = mode
        self.id = id
        if workflow {
            guard let view = values["view"].flatMap(UUID.init(uuidString:)),
                  let gesture = values["gesture"].flatMap(UUID.init(uuidString:)),
                  let library = values["library"].flatMap(URL.init(string:)),
                  let projectUID = values["project"], let projectName = values["projectName"],
                  values["output"] != nil else { throw RequestError.invalidURL }
            workflowOrigin = try WorkflowReviewOrigin(view: view, gesture: gesture,
                libraryURL: library, projectUID: projectUID, projectName: projectName)
        } else { workflowOrigin = nil }
        self.settings = try AnalysisSettings(
            thresholdDBFS: threshold, minimumSilenceDuration: minimum,
            beforeSpeechPadding: before, afterSpeechPadding: after, windowDuration: 0.01
        )
        if workflow { try WorkflowReviewOrigin.validate(settings: settings) }
    }

    public enum RequestError: LocalizedError {
        case invalidURL
        public var errorDescription: String? { "Silent Snip could not start analysis. In Final Cut Pro, choose Window → Extensions → Silent Snip, then analyze the clip again." }
    }
}

public enum SilentSnipOutputMode: String, Sendable {
    case remove, gaps

    public func gapDuration(frame: RationalTime) throws -> RationalTime? {
        guard self == .gaps else { return nil }
        let second = RationalTime(1)
        let lower = try second.roundedDown(toFrame: frame)
        let upper = try second.roundedUp(toFrame: frame)
        return try second.subtracting(lower) < upper.subtracting(second) && lower > .zero ? lower : upper
    }
}

/// Explicit recovery chosen in a native view; contains a local result, never media.
public struct ReviewVerificationRequest {
    public let view: UUID
    public let result: URL
    public let workflowOrigin: WorkflowReviewOrigin?
    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "silentsnip", ["verify", "workflow-verify"].contains(parts.host ?? ""), parts.path.isEmpty,
              parts.fragment == nil, parts.user == nil, parts.password == nil, parts.port == nil else {
            throw AnalyzeRequest.RequestError.invalidURL
        }
        let workflow = parts.host == "workflow-verify"
        let allowed: Set<String> = workflow ? ["view", "gesture", "library", "project", "projectName", "result"] : ["view", "result"]
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard allowed.contains(item.name), values[item.name] == nil, let value = item.value else {
                throw AnalyzeRequest.RequestError.invalidURL
            }
            values[item.name] = value
        }
        guard values.count == allowed.count,
              let view = values["view"].flatMap(UUID.init(uuidString:)),
              let path = values["result"],
              let result = URL(string: path), result.isFileURL,
              result.host == nil || result.host == "" || result.host == "localhost",
              result.path.hasPrefix("/"), result.query == nil, result.fragment == nil,
              result.user == nil, result.password == nil, result.port == nil,
              result.lastPathComponent == "Silent Snip.fcpxml" else { throw AnalyzeRequest.RequestError.invalidURL }
        if workflow {
            guard let gesture = values["gesture"].flatMap(UUID.init(uuidString:)),
                  let library = values["library"].flatMap(URL.init(string:)),
                  let project = values["project"], let name = values["projectName"] else {
                throw AnalyzeRequest.RequestError.invalidURL
            }
            workflowOrigin = try WorkflowReviewOrigin(view: view, gesture: gesture, libraryURL: library,
                projectUID: project, projectName: name)
        } else { workflowOrigin = nil }
        self.view = view; self.result = result
    }
}
