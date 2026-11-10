import Foundation
import SilentSnipCore

/// Detection settings supplied by a native Workflow Extension view. The URL
/// payload is a claim until its native gesture and fresh project XML both pass
/// verification. It never supplies a selected clip or permission to import.
public struct WorkflowReviewOrigin: Codable, Equatable, Sendable {
    public let view: UUID
    public let gesture: UUID
    public let libraryURL: URL
    public let projectUID: String
    public let projectName: String

    public init(view: UUID, gesture: UUID, libraryURL: URL, projectUID: String, projectName: String) throws {
        func valid(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                value.utf8.count <= 4096 && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
        guard libraryURL.isFileURL, libraryURL.path.hasPrefix("/"),
              libraryURL.host == nil || libraryURL.host == "" || libraryURL.host == "localhost",
              libraryURL.query == nil, libraryURL.fragment == nil,
              libraryURL.user == nil, libraryURL.password == nil, libraryURL.port == nil,
              libraryURL.pathExtension.lowercased() == "fcpbundle", valid(libraryURL.path),
              valid(projectUID), valid(projectName) else { throw AnalyzeRequest.RequestError.invalidURL }
        self.view = view
        self.gesture = gesture
        self.libraryURL = URL(fileURLWithPath: libraryURL.path, isDirectory: false).standardizedFileURL
        self.projectUID = projectUID
        self.projectName = projectName
    }

    private enum CodingKeys: String, CodingKey { case view, gesture, libraryURL, projectUID, projectName }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(view: values.decode(UUID.self, forKey: .view), gesture: values.decode(UUID.self, forKey: .gesture),
            libraryURL: values.decode(URL.self, forKey: .libraryURL),
            projectUID: values.decode(String.self, forKey: .projectUID), projectName: values.decode(String.self, forKey: .projectName))
    }

    func verify(projectData: Data) throws {
        let actual = try XMLReplacementTarget(projectData: projectData)
        guard actual.libraryURL.isFileURL,
              actual.libraryURL.host == nil || actual.libraryURL.host == "" || actual.libraryURL.host == "localhost",
              actual.libraryURL.query == nil, actual.libraryURL.fragment == nil,
              actual.libraryURL.user == nil, actual.libraryURL.password == nil, actual.libraryURL.port == nil,
              actual.libraryURL.standardizedFileURL.path == libraryURL.path,
              actual.originalProjectUID == projectUID, actual.projectName == projectName else {
            throw FinalCutCaptureError.changedProject
        }
    }

    static func validate(settings: AnalysisSettings) throws {
        for (name, value, range) in [
            ("Silence Threshold", settings.thresholdDBFS, -80.0...0.0),
            ("Minimum Silence", settings.minimumSilenceDuration, 0.0001...10.0),
            ("Before Speech", settings.beforeSpeechPadding, 0.0...2.0),
            ("After Speech", settings.afterSpeechPadding, 0.0...2.0)
        ] {
            guard value.isFinite, range.contains(value) else { throw AudioControllerSettingsError.invalidParameter(name) }
        }
        if let target = settings.pauseTargetDuration, !(0.001...10).contains(target) {
            throw AudioControllerSettingsError.invalidParameter("Target Pause")
        }
    }
}

/// Pure boundary checks shared by native AX validation and offline regressions.
enum WorkflowReviewGesture {
    static func pending(identifier: String?, enabled: Bool?, gesture: UUID, action: String) -> Bool {
        identifier == "silentsnip.workflow.\(action).requested.\(gesture.uuidString)" && enabled == false
    }

    static func authorizes(uniqueWindows: Int, focusedMatches: Bool, hostIsActive: Bool, helperIsActive: Bool = false,
                           identifier: String?, enabled: Bool?, gesture: UUID, action: String) -> Bool {
        uniqueWindows == 1 && focusedMatches &&
            WorkflowForegroundOwnership.permits(hostIsActive: hostIsActive, helperIsActive: helperIsActive) &&
            pending(identifier: identifier, enabled: enabled, gesture: gesture, action: action)
    }
}
