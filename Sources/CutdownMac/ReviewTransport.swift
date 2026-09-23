import Foundation
import CutdownCore

/// A small, local control channel. No audio or project XML crosses this channel.
/// App Sandbox permits distributed notifications with a string object and nil
/// userInfo. Notifications can be dropped, so clients poll the latest revision.
public enum ReviewWire {
    public static let version = 1
    public static let commandName = "local.cutdown.review.command.v1"
    public static let maximumBytes = 262_144
    public static func responseName(for request: UUID) -> String {
        "local.cutdown.review.response.v1.\(request.uuidString)"
    }

    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes, let result = String(data: data, encoding: .utf8) else {
            throw ReviewTransportError.invalidPayload
        }
        return result
    }

    public static func decodeCommand(_ object: Any?) throws -> ReviewCommand {
        guard let string = object as? String, let data = string.data(using: .utf8),
              data.count <= maximumBytes else { throw ReviewTransportError.invalidPayload }
        let command = try JSONDecoder().decode(ReviewCommand.self, from: data)
        guard command.version == version else { throw ReviewTransportError.invalidPayload }
        switch command.command {
        case .retryVerification:
            guard command.expectedRevision.map({ $0 >= 0 }) ?? true else { throw ReviewTransportError.invalidPayload }
        case .include:
            guard let id = command.cutID, !id.isEmpty, id.utf8.count <= 200,
                  command.included != nil else { throw ReviewTransportError.invalidPayload }
        case .preview:
            guard command.included != nil else { throw ReviewTransportError.invalidPayload }
        case .highlight:
            guard let id = command.cutID, !id.isEmpty, id.utf8.count <= 200 else {
                throw ReviewTransportError.invalidPayload
            }
        default: break
        }
        return command
    }
}

public struct ReviewWireSettings: Codable, Equatable, Sendable {
    public let threshold: Double
    public let minimum: Double
    public let before: Double
    public let after: Double

    public init(threshold: Double, minimum: Double, before: Double, after: Double) {
        self.threshold = threshold; self.minimum = minimum; self.before = before; self.after = after
    }

}

public struct ReviewCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case status, cancel, include, selectAll, deselectAll, highlight, apply, retryVerification, preview
    }
    public let version: Int
    public let request: UUID
    public let command: Kind
    public let cutID: String?
    public let included: Bool?
    /// A remote retry is accepted only for the failed revision the user saw.
    /// Retransmission cannot start another attempt after that revision changes.
    public let expectedRevision: Int?

    public init(request: UUID, command: Kind, cutID: String? = nil, included: Bool? = nil,
                expectedRevision: Int? = nil) {
        version = ReviewWire.version; self.request = request; self.command = command
        self.cutID = cutID; self.included = included
        self.expectedRevision = expectedRevision
    }
}

public struct ReviewCutResponse: Codable, Equatable, Sendable {
    public let id: String
    public let start: String
    public let end: String
    public let duration: String
    public let included: Bool
    public let eligible: Bool
    public let reason: String?

    public init(id: String, start: String, end: String, duration: String, included: Bool,
                eligible: Bool, reason: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.duration = duration
        self.included = included; self.eligible = eligible; self.reason = reason
    }
}

public struct ReviewResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let request: UUID
    public let revision: Int
    public let state: String
    public let message: String
    public let progress: Double?
    public let summary: String?
    public let cuts: [ReviewCutResponse]
    public let canApply: Bool
    public let canChangeSelection: Bool
    public let canCancel: Bool
    public let canHighlight: Bool
    public let previewVisible: Bool?
    public let canRetryVerification: Bool?

    public init(request: UUID, revision: Int, state: String, message: String,
                progress: Double? = nil,
                summary: String? = nil, cuts: [ReviewCutResponse] = [], canApply: Bool = false,
                canChangeSelection: Bool = false, canCancel: Bool = false, canHighlight: Bool = false, previewVisible: Bool? = nil, canRetryVerification: Bool? = nil) {
        version = ReviewWire.version; self.request = request; self.revision = revision
        self.state = state; self.message = message; self.progress = progress
        self.summary = summary; self.cuts = cuts
        self.canApply = canApply; self.canChangeSelection = canChangeSelection
        self.canCancel = canCancel; self.canHighlight = canHighlight
        self.previewVisible = previewVisible
        self.canRetryVerification = canRetryVerification
    }
}

/// One immutable, validated wire payload per revision. Status retries reuse its
/// bytes; the local helper still receives the original typed response.
public struct ReviewPublication: Sendable {
    public let response: ReviewResponse
    public let object: String

    public init(_ response: ReviewResponse) throws {
        guard response.revision >= 0, response.cuts.count <= 2000,
              response.progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
            throw ReviewTransportError.invalidPayload
        }
        self.object = try ReviewWire.encode(response)
        self.response = response
    }
}

/// A recreated host view may reconnect only after the helper verifies its
/// unique accessibility identifier and the original project/clip selection.
struct ReviewReconnectQuery: Codable {
    let version: Int
    let view: UUID
    static func decode(_ object: Any?) -> Self? {
        guard let text = object as? String, let data = text.data(using: .utf8), data.count <= 1024,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1 else { return nil }
        return value
    }
}
struct ReviewReconnectReply: Encodable {
    let version = 1
    let view: UUID
    let request: UUID
    let settings: ReviewWireSettings
    let output: String
    init(view: UUID, request: AnalyzeRequest) {
        self.view = view; self.request = request.id; self.output = request.outputMode.rawValue
        let s = request.settings
        settings = ReviewWireSettings(threshold: s.thresholdDBFS, minimum: s.minimumSilenceDuration,
            before: s.beforeSpeechPadding, after: s.afterSpeechPadding)
    }
}

/// The helper accepts commands only for jobs it already owns. This transport
/// never authorizes timeline edits: the application must validate its current
/// job, capabilities, baseline and recovery state for every operation.
@MainActor public final class ReviewTransport: NSObject {
    private var handler: ((ReviewCommand) -> Void)?
    public var onReconnect: ((UUID) -> AnalyzeRequest?)?

    public func start(handler: @escaping (ReviewCommand) -> Void) {
        stop()
        self.handler = handler
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reconnect(_:)),
            name: Notification.Name("local.cutdown.review.reconnect.v1"), object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)),
            name: Notification.Name(ReviewWire.commandName), object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        handler = nil
    }

    public func publish(_ response: ReviewResponse) throws {
        publish(try ReviewPublication(response))
    }

    public func publish(_ publication: ReviewPublication) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ReviewWire.responseName(for: publication.response.request)),
            object: publication.object, userInfo: nil, deliverImmediately: true)
    }

    public func connect(view: UUID, request: AnalyzeRequest) {
        guard let object = try? ReviewWire.encode(ReviewReconnectReply(view: view, request: request)) else { return }
        sendConnection(view: view, object: object)
    }

    public func connectionFailed(view: UUID, message: String) {
        struct Failure: Encodable { let version = 1; let view: UUID; let error: String }
        guard let object = try? ReviewWire.encode(Failure(view: view, error: message)) else { return }
        sendConnection(view: view, object: object)
    }

    private func sendConnection(view: UUID, object: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("local.cutdown.review.connected.v1.\(view.uuidString)"),
            object: object, userInfo: nil, deliverImmediately: true)
    }

    @objc private func reconnect(_ notification: Notification) {
        guard notification.userInfo == nil, let query = ReviewReconnectQuery.decode(notification.object),
              let request = onReconnect?(query.view) else { return }
        connect(view: query.view, request: request)
    }

    @objc private func receive(_ notification: Notification) {
        guard notification.userInfo == nil, let command = try? ReviewWire.decodeCommand(notification.object) else { return }
        handler?(command)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }
}

public enum ReviewTransportError: LocalizedError {
    case invalidPayload
    public var errorDescription: String? { "Cutdown received an invalid review message. Analyze again." }
}
