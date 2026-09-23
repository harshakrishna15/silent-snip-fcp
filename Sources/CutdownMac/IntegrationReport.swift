import Foundation
import CutdownCore

public struct IntegrationReport: Codable, Sendable {
    public let date: Date
    public let requestID: UUID?
    public let settings: AnalysisSettings?
    public let state: String
    public let message: String

    public init(request: AnalyzeRequest? = nil, state: String, message: String) {
        self.date = Date()
        self.requestID = request?.id
        self.settings = request?.settings
        self.state = state
        self.message = message
    }

    public static var reportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutdown/Integration/latest.json")
    }

    public func save() throws {
        let url = Self.reportURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
