import Foundation
import SilentSnipWorkflowModel

/// Objective-C UI owns host observations; this bridge only persists validated
/// values inside this extension's own sandbox. No Final Cut preferences or
/// production Silent Snip files are opened.
@MainActor
@objc(SSWorkflowSettingsBridge)
public final class WorkflowSettingsBridge: NSObject {
    // Controller instances share one lazily initialized writer and setup
    // result. Atomic file replacement alone does not serialize two actors'
    // read-modify-write cycles. Cross-process/external writers are unsupported.
    private static let persistence: Result<WorkflowSettingsStore, Error> = Result {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Silent Snip Workflow Prototype", isDirectory: true)
        return try WorkflowSettingsStore(fileURL: root.appendingPathComponent("Project-Settings.json"))
    }

    private let store: WorkflowSettingsStore?
    private let setupError: NSError?

    public override init() {
        switch Self.persistence {
        case .success(let sharedStore):
            store = sharedStore
            setupError = nil
        case .failure(let error):
            store = nil
            setupError = error as NSError
        }
        super.init()
    }

    @objc(loadForLibraryURL:projectUID:completion:)
    public func load(libraryURL: URL, projectUID: String,
                     completion: @escaping (NSDictionary?, NSError?) -> Void) {
        guard let store else { completion(nil, setupError); return }
        Task {
            do {
                let identity = try WorkflowProjectIdentity(libraryURL: libraryURL, projectUID: projectUID)
                let saved = try await store.settings(for: identity)
                let settings = saved ?? .defaults
                let values: NSDictionary = ["thresholdDBFS": settings.thresholdDBFS,
                    "minimumSilenceDuration": settings.minimumSilenceDuration,
                    "beforeSpeechPadding": settings.beforeSpeechPadding,
                    "afterSpeechPadding": settings.afterSpeechPadding,
                    "outputMode": settings.outputMode.rawValue,
                    "wasSaved": saved != nil]
                completion(values, nil)
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    @objc(saveValues:libraryURL:projectUID:completion:)
    public func save(values: NSDictionary, libraryURL: URL, projectUID: String,
                     completion: @escaping (NSError?) -> Void) {
        guard let store else { completion(setupError); return }
        Task {
            do {
                func number(_ key: String) throws -> Double {
                    guard let value = values[key] as? NSNumber else {
                        throw WorkflowModelError.invalidSetting(key)
                    }
                    return value.doubleValue
                }
                guard let raw = values["outputMode"] as? String,
                      let mode = WorkflowOutputMode(rawValue: raw) else {
                    throw WorkflowModelError.invalidSetting("output mode")
                }
                let settings = try WorkflowSettings(thresholdDBFS: number("thresholdDBFS"),
                    minimumSilenceDuration: number("minimumSilenceDuration"),
                    beforeSpeechPadding: number("beforeSpeechPadding"),
                    afterSpeechPadding: number("afterSpeechPadding"), outputMode: mode)
                let identity = try WorkflowProjectIdentity(libraryURL: libraryURL, projectUID: projectUID)
                try await store.save(settings, for: identity)
                completion(nil)
            } catch {
                completion(error as NSError)
            }
        }
    }
}
