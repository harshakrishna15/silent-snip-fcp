import Foundation

public enum WorkflowOutputMode: String, Codable, CaseIterable, Sendable {
    case remove
    case gaps
}

/// Prototype controls use the same supported ranges as Silent Snip Audio.
/// Decoding passes through the initializer so an invalid saved value cannot
/// become an apparently valid set of controls.
public struct WorkflowSettings: Codable, Equatable, Sendable {
    public let thresholdDBFS: Double
    public let minimumSilenceDuration: Double
    public let beforeSpeechPadding: Double
    public let afterSpeechPadding: Double
    public let outputMode: WorkflowOutputMode

    public static let defaults = try! WorkflowSettings()

    public init(thresholdDBFS: Double = -40, minimumSilenceDuration: Double = 0.5,
                beforeSpeechPadding: Double = 0.1, afterSpeechPadding: Double = 0.1,
                outputMode: WorkflowOutputMode = .remove) throws {
        for (field, value, range) in [
            ("silence threshold", thresholdDBFS, -80.0...0.0),
            ("minimum silence", minimumSilenceDuration, 0.0001...10.0),
            ("padding before speech", beforeSpeechPadding, 0.0...2.0),
            ("padding after speech", afterSpeechPadding, 0.0...2.0)
        ] {
            guard value.isFinite, range.contains(value) else {
                throw WorkflowModelError.invalidSetting(field)
            }
        }
        self.thresholdDBFS = thresholdDBFS
        self.minimumSilenceDuration = minimumSilenceDuration
        self.beforeSpeechPadding = beforeSpeechPadding
        self.afterSpeechPadding = afterSpeechPadding
        self.outputMode = outputMode
    }

    private enum CodingKeys: String, CodingKey {
        case thresholdDBFS, minimumSilenceDuration, beforeSpeechPadding, afterSpeechPadding, outputMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            thresholdDBFS: values.decode(Double.self, forKey: .thresholdDBFS),
            minimumSilenceDuration: values.decode(Double.self, forKey: .minimumSilenceDuration),
            beforeSpeechPadding: values.decode(Double.self, forKey: .beforeSpeechPadding),
            afterSpeechPadding: values.decode(Double.self, forKey: .afterSpeechPadding),
            outputMode: values.decode(WorkflowOutputMode.self, forKey: .outputMode)
        )
    }
}
