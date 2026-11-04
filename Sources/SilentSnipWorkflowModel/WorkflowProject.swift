import Foundation

public enum WorkflowModelError: Error, Equatable, LocalizedError {
    case invalidIdentity(String)
    case invalidSetting(String)
    case invalidPlayhead
    case unboundProject
    case invalidStoreURL
    case unsupportedSchema(Int)
    case invalidArchive

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity(let field): return "The verified project identity is missing a valid \(field)."
        case .invalidSetting(let field): return "The \(field) setting is outside its supported range."
        case .invalidPlayhead: return "The host playhead time is not finite."
        case .unboundProject: return "Settings require a verified library and project identity."
        case .invalidStoreURL: return "The settings store requires a local file URL."
        case .unsupportedSchema(let version): return "Settings schema \(version) is not supported."
        case .invalidArchive: return "The saved project settings are invalid. The file was kept."
        }
    }
}

/// The caller must obtain the library URL and project UID from one verified
/// host hierarchy. The Workflow Extension SDK does not expose a library UID.
/// Display names and a sequence UID alone cannot supply that binding. The URL
/// is standardized lexically without opening the library or resolving aliases.
/// A moved library therefore needs a new binding; names never recover one.
public struct WorkflowProjectIdentity: Codable, Hashable, Sendable {
    public let libraryURL: URL
    public let projectUID: String

    public init(libraryURL: URL, projectUID: String) throws {
        guard Self.isLocalFileURL(libraryURL), libraryURL.path != "/" else {
            throw WorkflowModelError.invalidIdentity("library URL")
        }
        guard !projectUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              projectUID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WorkflowModelError.invalidIdentity("project UID")
        }
        // Normalize a local-host file URL to the same form as file:///… and
        // preserve its path without consulting filesystem identity or aliases.
        self.libraryURL = URL(fileURLWithPath: libraryURL.path, isDirectory: false).standardizedFileURL
        self.projectUID = projectUID
    }

    private enum CodingKeys: String, CodingKey { case libraryURL, projectUID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(libraryURL: values.decode(URL.self, forKey: .libraryURL),
                      projectUID: values.decode(String.self, forKey: .projectUID))
    }

    static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && url.query == nil && url.fragment == nil &&
            (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
    }
}

/// An observed project may be displayed before its stable identity is proven.
/// That unbound observation must not enable settings persistence.
public struct WorkflowProjectContext: Equatable, Sendable {
    public let name: String
    public let identity: WorkflowProjectIdentity?

    public init(name: String, identity: WorkflowProjectIdentity? = nil) {
        self.name = name
        self.identity = identity
    }
}

/// Read-only host observations. The Workflow Extension timeline API does not
/// prove which clip is selected; no selected-clip state is represented here.
public struct WorkflowHostSnapshot: Equatable, Sendable {
    public let hostName: String?
    public let hostVersion: String?
    public let project: WorkflowProjectContext?
    public let playheadSeconds: Double?

    public init(hostName: String? = nil, hostVersion: String? = nil,
                project: WorkflowProjectContext? = nil, playheadSeconds: Double? = nil) throws {
        if let playheadSeconds, !playheadSeconds.isFinite {
            throw WorkflowModelError.invalidPlayhead
        }
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.project = project
        self.playheadSeconds = playheadSeconds
    }

    public var isProjectBound: Bool { project?.identity != nil }
}
